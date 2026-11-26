//! Parent transport and no-follow capture of canonical Linux symlink metadata.
use crate::{
	Directory, EntryInfo, Error, Identity, Kind,
	linux_snapshot_metadata::{self, Limits},
	linux_transport::optional,
	owned, xattr,
};
use difz_core::{
	metadata::{CanonicalMetadata, Family, Metadata, Omit},
	symlink_transport::{self, Record, Transport},
};
use std::{borrow::Cow, io};

/// Owned records survive temporary transport storage. Parent identity is
/// checked on use, so a frame can move its directory handle without a
/// self-reference or an extra descriptor per level.
pub struct ParentTransport {
	identity: Identity,
	omit: Omit,
	limits: Limits,
	transport: Option<Transport<'static>>,
}
impl ParentTransport {
	pub fn read(parent: &Directory, omit: Omit, limits: Limits) -> Result<Self, Error> {
		let identity = parent.inspect_self()?.identity;
		let all = Family::ALL
			.iter()
			.fold(0, |bits, family| bits | family.bit());
		let blob = if omit.bits() == all {
			None
		} else {
			optional(
				&parent.file,
				b"user.difz.symlinks",
				limits.metadata_bytes.min(symlink_transport::MAX_BYTES),
			)?
		};
		let transport = match blob {
			None => None,
			Some(bytes) => {
				let decoded = Transport::decode(&bytes).map_err(Error::Transport)?;
				let mut records = Vec::new();
				records
					.try_reserve_exact(decoded.records().len())
					.map_err(|_| Error::OutOfMemory)?;
				for Record {
					name,
					metadata,
					absent_times,
					observed_mtime,
					acl_override,
					finder_override,
				} in decoded.into_records()
				{
					match parent.inspect(&name) {
						Ok(info) if info.kind == Kind::Symlink => {}
						Ok(_) => {
							return Err(Error::Transport(
								symlink_transport::Error::InvalidTransport,
							));
						}
						Err(Error::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
							return Err(Error::Transport(
								symlink_transport::Error::InvalidTransport,
							));
						}
						Err(error) => return Err(error),
					}
					records.push(Record {
						name: Cow::Owned(owned(&name)?),
						metadata: metadata.into_owned().map_err(Error::Metadata)?,
						absent_times,
						observed_mtime,
						acl_override,
						finder_override,
					});
				}
				Some(Transport::new(records).map_err(Error::Transport)?)
			}
		};
		let value = Self {
			identity,
			omit,
			limits,
			transport,
		};
		value.check_parent(parent)?;
		Ok(value)
	}
	pub fn capture(
		&self,
		parent: &Directory,
		name: &[u8],
	) -> Result<(EntryInfo, CanonicalMetadata<'static>), Error> {
		self.check_parent(parent)?;
		let reader = xattr::Symlink::open(parent, name)?;
		let mut native = linux_snapshot_metadata::capture_symlink(&reader, self.omit, self.limits)?
			.into_metadata();
		if let Some(record) = self
			.transport
			.as_ref()
			.and_then(|transport| transport.find(name))
		{
			let kept = record
				.metadata
				.borrowing_omitting(self.omit)
				.map_err(Error::Metadata)?
				.into_owned()
				.map_err(Error::Metadata)?
				.into_metadata();
			merge(&mut native, kept, record, self.limits.attributes)?;
		}
		reader.verify()?;
		let metadata = CanonicalMetadata::normalize(native, self.omit).map_err(Error::Metadata)?;
		if metadata.encoded_len().map_err(Error::Metadata)? > self.limits.metadata_bytes {
			return Err(Error::LimitExceeded);
		}
		Ok((reader.info(), metadata))
	}
	fn check_parent(&self, parent: &Directory) -> Result<(), Error> {
		if parent.inspect_self()?.identity != self.identity {
			return Err(io::Error::new(
				io::ErrorKind::InvalidInput,
				"symlink transport belongs to another directory",
			)
			.into());
		}
		Ok(())
	}
}
fn merge(
	native: &mut Metadata<'static>,
	kept: Metadata<'static>,
	record: &Record<'_>,
	maximum_attributes: usize,
) -> Result<(), Error> {
	let Metadata {
		xattrs,
		aces,
		native_acl,
		times,
		finder_flags,
		finder_info,
		holes,
		hardlink_to,
	} = kept;
	if !holes.is_empty() || hardlink_to.is_some() {
		return Err(Error::Transport(symlink_transport::Error::InvalidTransport));
	}
	// Both input records are canonical. Search the original sorted native
	// prefix while appending transported fields; native values take precedence.
	let count = native.xattrs.len();
	for value in xattrs {
		if native.xattrs[..count]
			.binary_search_by(|other| {
				(other.class, other.name.as_ref()).cmp(&(value.class, value.name.as_ref()))
			})
			.is_ok()
		{
			continue;
		}
		if native.xattrs.len() >= maximum_attributes {
			return Err(Error::LimitExceeded);
		}
		native
			.xattrs
			.try_reserve(1)
			.map_err(|_| Error::OutOfMemory)?;
		native.xattrs.push(value);
	}
	if record.acl_override || !aces.is_empty() {
		native.aces = aces;
	}
	if record.acl_override || native_acl.is_some() {
		native.native_acl = native_acl;
	}
	if native.times.mtime == record.observed_mtime
		&& (times.mtime.is_some() || record.absent_times & 1 != 0)
	{
		native.times.mtime = times.mtime;
	}
	if times.atime.is_some() || record.absent_times & 2 != 0 {
		native.times.atime = times.atime;
	}
	if times.btime.is_some() || record.absent_times & 4 != 0 {
		native.times.btime = times.btime;
	}
	if record.finder_override || finder_flags != 0 {
		native.finder_flags = finder_flags;
	}
	if record.finder_override || finder_info.is_some() {
		native.finder_info = finder_info;
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use difz_core::metadata::{NativeAcl, Os, Time, Times, Xattr, XattrClass};
	use std::{
		fs,
		os::{fd::AsRawFd, unix::fs::symlink},
		path::Path,
		process::Command,
	};
	fn oracle(root: &Path, output: &Path, extra: &[&str]) -> CanonicalMetadata<'static> {
		let result = Command::new(env!("DIFZ_ORACLE"))
			.arg("--no-progress")
			.args(extra)
			.arg(root)
			.arg(root)
			.arg("-o")
			.arg(output)
			.output()
			.unwrap();
		assert!(
			result.status.success(),
			"{}",
			String::from_utf8_lossy(&result.stderr)
		);
		let bytes = fs::read(output).unwrap();
		let patch = difz_core::tree_patch::ParsedPatch::decode(
			&bytes,
			difz_core::tree_patch::Limits::default(),
		)
		.unwrap();
		patch
			.entries()
			.iter()
			.find(|entry| entry.path() == b"link")
			.unwrap()
			.metadata()
			.borrowing_omitting(Omit::default())
			.unwrap()
			.into_owned()
			.unwrap()
	}
	#[test]
	fn native_parent_transport_matches_the_existing_cli_after_parent_rename_and_a_stale_mtime_witness()
	 {
		let fixture = Fixture::new();
		let root = fixture.0.join("root");
		fs::create_dir(&root).unwrap();
		fs::write(root.join("target"), b"payload").unwrap();
		symlink("target", root.join("link")).unwrap();
		let parent = Directory::open(&root).unwrap();
		let observed = parent.inspect(b"link").unwrap().mtime;
		let desired = CanonicalMetadata::new(Metadata {
			xattrs: vec![Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"note"),
				value: Cow::Borrowed(b"binary\0\xff"),
			}],
			native_acl: Some(NativeAcl {
				origin: Os::Macos,
				bytes: Cow::Borrowed(b"foreign\0acl"),
			}),
			finder_flags: 19,
			times: Times {
				mtime: Some(Time { sec: -5, nsec: 7 }),
				btime: Some(Time { sec: -9, nsec: 11 }),
				atime: None,
			},
			..Metadata::default()
		})
		.unwrap();
		let bytes = Transport::new(vec![Record {
			name: Cow::Borrowed(b"link"),
			metadata: desired,
			absent_times: 0,
			observed_mtime: Some(observed),
			acl_override: true,
			finder_override: true,
		}])
		.unwrap()
		.encode()
		.unwrap();
		xattr::set(&parent.file, b"user.difz.symlinks", &bytes).unwrap();
		let stored = ParentTransport::read(&parent, Omit::default(), Limits::default()).unwrap();
		let moved = fixture.0.join("moved");
		fs::rename(&root, &moved).unwrap();
		fs::create_dir(&root).unwrap();
		let (_, captured) = stored.capture(&parent, b"link").unwrap();
		assert_eq!(
			captured,
			oracle(&moved, &fixture.0.join("native.patch"), &[])
		);
		assert_eq!(
			captured.metadata().xattrs[0].value.as_ref(),
			b"binary\0\xff"
		);
		assert!(captured.metadata().hardlink_to.is_none());
		let times = [
			libc::timespec {
				tv_sec: 0,
				tv_nsec: libc::UTIME_OMIT,
			},
			libc::timespec {
				tv_sec: 31,
				tv_nsec: 13,
			},
		];
		assert_eq!(
			unsafe {
				libc::utimensat(
					parent.file.as_raw_fd(),
					c"link".as_ptr(),
					times.as_ptr(),
					libc::AT_SYMLINK_NOFOLLOW,
				)
			},
			0
		);
		let (_, captured) = stored.capture(&parent, b"link").unwrap();
		assert_eq!(
			captured.metadata().times.mtime,
			Some(Time { sec: 31, nsec: 13 })
		);
		assert_eq!(
			captured,
			oracle(&moved, &fixture.0.join("stale.patch"), &[])
		);
	}
	#[test]
	fn native_parent_transport_rejects_wrong_entries_and_parent_identity_and_obeys_omission_and_limits()
	 {
		let fixture = Fixture::new();
		fs::write(fixture.0.join("target"), b"payload").unwrap();
		symlink("target", fixture.0.join("link")).unwrap();
		let parent = Directory::open(&fixture.0).unwrap();
		let metadata = CanonicalMetadata::new(Metadata {
			finder_flags: 1,
			..Metadata::default()
		})
		.unwrap();
		let bytes = Transport::new(vec![Record {
			name: Cow::Borrowed(b"target"),
			metadata,
			absent_times: 0,
			observed_mtime: None,
			acl_override: false,
			finder_override: true,
		}])
		.unwrap()
		.encode()
		.unwrap();
		xattr::set(&parent.file, b"user.difz.symlinks", &bytes).unwrap();
		assert!(matches!(
			ParentTransport::read(&parent, Omit::default(), Limits::default()),
			Err(Error::Transport(symlink_transport::Error::InvalidTransport))
		));
		let all = Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap();
		let ignored = ParentTransport::read(&parent, all, Limits::default()).unwrap();
		assert!(
			ignored
				.capture(&parent, b"link")
				.unwrap()
				.1
				.metadata()
				.is_empty()
		);
		fs::create_dir(fixture.0.join("other")).unwrap();
		assert!(
			ignored
				.capture(&Directory::open(&fixture.0.join("other")).unwrap(), b"link")
				.is_err()
		);
		assert!(matches!(
			ParentTransport::read(
				&parent,
				Omit::default(),
				Limits {
					metadata_bytes: bytes.len() - 1,
					..Limits::default()
				}
			),
			Err(Error::LimitExceeded)
		));
	}
}
