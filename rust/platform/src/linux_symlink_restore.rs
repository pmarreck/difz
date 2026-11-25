//! Native symlink restoration and records for an enclosing owned stage's parent.
use crate::{
	Directory, Error, Kind, basename,
	linux_snapshot_metadata::{self, Limits},
	xattr,
};
use difz_core::{
	metadata::{self, CanonicalMetadata, Metadata, Omit, Os, Time, XattrClass},
	symlink_transport::Record,
};
use std::{borrow::Cow, io, os::fd::AsRawFd};

impl Directory {
	pub fn set_symlink_mtime(&self, name: &[u8], desired: Time) -> Result<(), Error> {
		if desired.nsec >= 1_000_000_000 {
			return Err(Error::Metadata(metadata::Error::InvalidNsec));
		}
		let before = self.inspect(name)?;
		if before.kind != Kind::Symlink {
			return Err(Error::WrongKind);
		}
		let name = basename(name)?;
		let values = [
			libc::timespec {
				tv_sec: 0,
				tv_nsec: libc::UTIME_OMIT,
			},
			libc::timespec {
				tv_sec: desired.sec,
				tv_nsec: i64::from(desired.nsec),
			},
		];
		// Borrowed parent descriptor, terminated basename and initialized array.
		// NOFOLLOW selects the link; access time remains outside our profile.
		let result = unsafe {
			libc::utimensat(
				self.file.as_raw_fd(),
				name.as_ptr().cast(),
				values.as_ptr(),
				libc::AT_SYMLINK_NOFOLLOW,
			)
		};
		if result < 0 {
			return Err(io::Error::last_os_error().into());
		}
		let mut after = self.inspect(&name[..name.len() - 1])?;
		after.mtime = before.mtime;
		if after != before {
			return Err(changed("symlink identity changed while setting time"));
		}
		Ok(())
	}
}

/// The caller owns a fresh staging link. Return the exact fields that still
/// need parent transport, including explicit absence and a raw mtime witness.
/// The enclosing stage must store the returned record and verify final capture
/// before publication. Errors may follow native effects; the stage owns rollback.
pub fn prepare<'a>(
	parent: &Directory,
	name: &'a [u8],
	desired: &'a CanonicalMetadata<'_>,
	omit: Omit,
	limits: Limits,
) -> Result<Option<Record<'a>>, Error> {
	let desired = desired.borrowing_omitting(omit).map_err(Error::Metadata)?;
	if !desired.metadata().holes.is_empty() || desired.metadata().hardlink_to.is_some() {
		return Err(Error::Metadata(metadata::Error::BadMetadata));
	}
	if desired.metadata().xattrs.len() > limits.attributes
		|| desired.encoded_len().map_err(Error::Metadata)? > limits.metadata_bytes
	{
		return Err(Error::LimitExceeded);
	}
	let writer = xattr::Symlink::open(parent, name)?;
	for value in &desired.metadata().xattrs {
		if value.class == XattrClass::Raw && !metadata::raw_accepted(Os::Linux, &value.name) {
			continue;
		}
		let mut storage = [0u8; 256];
		let native =
			metadata::attribute_name::to_native(Os::Linux, value.class, &value.name, &mut storage)
				.map_err(|_| Error::InvalidAttributeName)?;
		match writer.set(native.to_bytes(), &value.value) {
			Ok(()) => {}
			Err(Error::Io(error))
				if matches!(
					error.raw_os_error(),
					Some(libc::EPERM | libc::EACCES | libc::ENOTSUP)
				) => {}
			Err(error) => return Err(error),
		}
	}
	drop(writer);
	if let Some(time) = desired.metadata().times.mtime {
		match parent.set_symlink_mtime(name, time) {
			Ok(()) => {}
			Err(Error::Io(error)) if error.kind() != io::ErrorKind::InvalidData => {}
			Err(error) => return Err(error),
		}
	}
	let reader = xattr::Symlink::open(parent, name)?;
	let actual = linux_snapshot_metadata::capture_symlink(&reader, omit, limits)?;
	let mut kept = Metadata::default();
	let mut wanted = desired.into_metadata();
	for value in wanted.xattrs {
		match actual.metadata().xattrs.binary_search_by(|other| {
			(other.class, other.name.as_ref()).cmp(&(value.class, value.name.as_ref()))
		}) {
			Ok(index) if actual.metadata().xattrs[index].value == value.value => {}
			Ok(_) => {
				return Err(changed(
					"a native symlink attribute would override its transport",
				));
			}
			Err(_) => {
				kept.xattrs.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
				kept.xattrs.push(value);
			}
		}
	}
	let acl_override =
		actual.metadata().aces != wanted.aces || actual.metadata().native_acl != wanted.native_acl;
	if acl_override {
		kept.aces = std::mem::take(&mut wanted.aces);
		kept.native_acl = wanted.native_acl.take();
	}
	let finder_override = actual.metadata().finder_flags != wanted.finder_flags
		|| actual.metadata().finder_info != wanted.finder_info;
	if finder_override {
		kept.finder_flags = wanted.finder_flags;
		kept.finder_info = wanted.finder_info;
	}
	let mut absent_times = 0;
	let keep_mtime = actual.metadata().times.mtime != wanted.times.mtime;
	if keep_mtime {
		kept.times.mtime = wanted.times.mtime;
		if wanted.times.mtime.is_none() {
			absent_times |= 1;
		}
	}
	if actual.metadata().times.atime != wanted.times.atime {
		kept.times.atime = wanted.times.atime;
		if wanted.times.atime.is_none() {
			absent_times |= 2;
		}
	}
	if actual.metadata().times.btime != wanted.times.btime {
		kept.times.btime = wanted.times.btime;
		if wanted.times.btime.is_none() {
			absent_times |= 4;
		}
	}
	reader.verify()?;
	if kept.is_empty() && absent_times == 0 && !acl_override && !finder_override {
		return Ok(None);
	}
	Ok(Some(Record {
		name: Cow::Borrowed(name),
		metadata: CanonicalMetadata::new(kept).map_err(Error::Metadata)?,
		absent_times,
		observed_mtime: keep_mtime.then_some(reader.info().mtime),
		acl_override,
		finder_override,
	}))
}
fn changed(message: &'static str) -> Error {
	io::Error::new(io::ErrorKind::InvalidData, message).into()
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{linux_symlink_capture::ParentTransport, tests::Fixture};
	use difz_core::{
		metadata::{Ace, AceTag, NativeAcl, Permissions, Times, Xattr},
		symlink_transport::Transport,
	};
	use std::{
		fs,
		os::unix::fs::symlink,
		time::{Duration, UNIX_EPOCH},
	};
	#[test]
	fn setting_link_time_uses_nofollow_and_rejects_invalid_values_and_regular_files() {
		let fixture = Fixture::new();
		fs::write(fixture.0.join("target"), b"retained").unwrap();
		symlink("target", fixture.0.join("link")).unwrap();
		let parent = Directory::open(&fixture.0).unwrap();
		let before = fs::metadata(fixture.0.join("target"))
			.unwrap()
			.modified()
			.unwrap();
		parent
			.set_symlink_mtime(b"link", Time { sec: -3, nsec: 7 })
			.unwrap();
		assert_eq!(
			fs::symlink_metadata(fixture.0.join("link"))
				.unwrap()
				.modified()
				.unwrap(),
			UNIX_EPOCH - Duration::new(2, 999_999_993)
		);
		assert_eq!(
			fs::metadata(fixture.0.join("target"))
				.unwrap()
				.modified()
				.unwrap(),
			before
		);
		assert!(matches!(
			parent.set_symlink_mtime(
				b"link",
				Time {
					sec: 9,
					nsec: 1_000_000_000
				}
			),
			Err(Error::Metadata(metadata::Error::InvalidNsec))
		));
		assert!(matches!(
			parent.set_symlink_mtime(b"target", Time { sec: 9, nsec: 0 }),
			Err(Error::WrongKind)
		));
	}
	#[test]
	fn native_symlink_restore_round_trips_all_transport_fields_without_mutating_its_target() {
		let fixture = Fixture::new();
		fs::write(fixture.0.join("target"), b"target-data").unwrap();
		symlink("target", fixture.0.join("link")).unwrap();
		let parent = Directory::open(&fixture.0).unwrap();
		let target = parent.open_regular_file(b"target").unwrap();
		xattr::set(&target, b"user.name", b"target-original").unwrap();
		let before = target.metadata().unwrap().modified().unwrap();
		let desired = CanonicalMetadata::new(Metadata {
			xattrs: vec![Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"name"),
				value: Cow::Borrowed(b"link\0\xff"),
			}],
			aces: vec![Ace {
				tag: AceTag::NamedUser,
				permissions: Permissions::READ,
				name: Cow::Borrowed(b"foreign-user"),
			}],
			native_acl: Some(NativeAcl {
				origin: Os::Macos,
				bytes: Cow::Borrowed(b"foreign\0acl"),
			}),
			finder_flags: 5,
			finder_info: Some([0xa5; 32]),
			times: Times {
				mtime: Some(Time { sec: -7, nsec: 11 }),
				atime: Some(Time { sec: -13, nsec: 19 }),
				btime: None,
			},
			..Metadata::default()
		})
		.unwrap();
		let record = prepare(
			&parent,
			b"link",
			&desired,
			Omit::default(),
			Limits::default(),
		)
		.unwrap()
		.unwrap();
		let bytes = Transport::new(vec![record]).unwrap().encode().unwrap();
		xattr::set(&parent.file, b"user.difz.symlinks", &bytes).unwrap();
		let (_, actual) = ParentTransport::read(&parent, Omit::default(), Limits::default())
			.unwrap()
			.capture(&parent, b"link")
			.unwrap();
		assert_eq!(actual, desired);
		assert_eq!(
			xattr::get(&target, b"user.name", 65_536)
				.unwrap()
				.as_deref(),
			Some(b"target-original".as_slice())
		);
		assert_eq!(target.metadata().unwrap().modified().unwrap(), before);
		assert_eq!(fs::read(fixture.0.join("target")).unwrap(), b"target-data");
	}
}
