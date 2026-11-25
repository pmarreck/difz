//! Attribute and Finder restoration on owned Linux staging objects.
use crate::{EntryInfo, Error, Kind, linux_capture, linux_transport, xattr};
use difz_core::metadata::{
	self, CanonicalMetadata, CompromiseCode, Family, Metadata, Omit, Os, RestoreReport, XattrClass,
};
use std::{fs::File, io};

/// Logical attributes must reach their native names. Raw attributes that
/// cannot be stored retain exact name/value bytes in canonical transport.
/// Existing unrelated attributes are retained and cause readback to fail;
/// callers supply freshly created staging objects and own rollback.
pub fn xattrs(
	file: &File,
	desired: &CanonicalMetadata<'_>,
	maximum_names: usize,
	maximum_bytes: usize,
) -> Result<RestoreReport, Error> {
	ordinary(file)?;
	let desired = family(desired, Family::Xattr)?;
	if desired.metadata().xattrs.len() > maximum_names
		|| desired.encoded_len().map_err(Error::Metadata)? > maximum_bytes
	{
		return Err(Error::LimitExceeded);
	}
	let expected = desired.hash();
	let mut preserved = Vec::new();
	for value in desired.into_metadata().xattrs {
		let mut storage = [0u8; 256];
		let native =
			metadata::attribute_name::to_native(Os::Linux, value.class, &value.name, &mut storage)
				.map_err(|_| Error::InvalidAttributeName)?;
		match value.class {
			XattrClass::Logical => xattr::set(file, native.to_bytes(), &value.value)?,
			XattrClass::Raw => {
				let preserve = if metadata::raw_accepted(Os::Linux, &value.name) {
					match xattr::set(file, native.to_bytes(), &value.value) {
						Ok(()) => false,
						Err(Error::Io(error))
							if matches!(
								error.raw_os_error(),
								Some(libc::EPERM | libc::EACCES | libc::ENOTSUP)
							) =>
						{
							true
						}
						Err(error) => return Err(error),
					}
				} else {
					true
				};
				if preserve {
					preserved.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
					preserved.push(value);
				}
			}
		}
	}
	let mut report = RestoreReport::default();
	if preserved.is_empty() {
		remove(file, b"user.difz.raw-xattrs")?;
	} else {
		put(
			file,
			b"user.difz.raw-xattrs",
			Metadata {
				xattrs: preserved,
				..Metadata::default()
			},
		)?;
		report.add(CompromiseCode::RawXattrPreserved);
	}
	let captured = CanonicalMetadata::normalize(
		Metadata {
			xattrs: linux_transport::capture_xattrs(file, maximum_names, maximum_bytes)?,
			..Metadata::default()
		},
		Omit::default(),
	)
	.map_err(Error::Metadata)?;
	if captured.hash() != expected {
		return Err(changed());
	}
	Ok(report)
}

pub fn finder(
	file: &File,
	desired: &CanonicalMetadata<'_>,
	maximum_bytes: usize,
) -> Result<RestoreReport, Error> {
	ordinary(file)?;
	let desired = family(desired, Family::Finder)?;
	if desired.encoded_len().map_err(Error::Metadata)? > maximum_bytes {
		return Err(Error::LimitExceeded);
	}
	let mut report = RestoreReport::default();
	let value = desired.metadata();
	if value.finder_flags == 0 {
		remove(file, b"user.difz.bsd-flags")?;
	} else {
		put(
			file,
			b"user.difz.bsd-flags",
			Metadata {
				finder_flags: value.finder_flags,
				..Metadata::default()
			},
		)?;
		report.add(CompromiseCode::FinderFlagsPreserved);
	}
	if value.finder_info.is_none() {
		remove(file, b"user.difz.finder-info")?;
	} else {
		put(
			file,
			b"user.difz.finder-info",
			Metadata {
				finder_info: value.finder_info,
				..Metadata::default()
			},
		)?;
		report.add(CompromiseCode::FinderInfoPreserved);
	}
	let actual = CanonicalMetadata::new(linux_capture::capture_finder(file, maximum_bytes)?)
		.map_err(Error::Metadata)?;
	if actual != desired {
		return Err(changed());
	}
	Ok(report)
}
fn ordinary(file: &File) -> Result<(), Error> {
	match EntryInfo::for_file(file)?.kind {
		Kind::File | Kind::Directory => Ok(()),
		Kind::Symlink | Kind::Other => Err(Error::WrongKind),
	}
}
fn family<'a>(
	metadata: &'a CanonicalMetadata<'_>,
	selected: Family,
) -> Result<CanonicalMetadata<'a>, Error> {
	let excluded = Family::ALL
		.iter()
		.filter(|&&value| value != selected)
		.fold(0, |bits, value| bits | value.bit());
	metadata
		.borrowing_omitting(Omit::from_bits(excluded).map_err(Error::Metadata)?)
		.map_err(Error::Metadata)
}
fn remove(file: &File, name: &[u8]) -> Result<(), Error> {
	match xattr::remove(file, name) {
		Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOTSUP) => Ok(()),
		result => result.map(|_| ()),
	}
}
fn put(file: &File, name: &[u8], value: Metadata<'_>) -> Result<(), Error> {
	let bytes = CanonicalMetadata::new(value)
		.map_err(Error::Metadata)?
		.encode()
		.map_err(Error::Metadata)?;
	xattr::set(file, name, &bytes)
}
fn changed() -> Error {
	io::Error::new(
		io::ErrorKind::InvalidData,
		"attribute restoration readback mismatch",
	)
	.into()
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{Directory, tests::Fixture};
	use difz_core::metadata::Xattr;
	use std::{borrow::Cow, ffi::CString, fs, os::fd::AsRawFd};
	#[test]
	fn native_attribute_restore_keeps_binary_empty_raw_and_foreign_values_on_open_identity() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		let file = parent.create_file(b"data").unwrap();
		fs::rename(fixture.0.join("data"), fixture.0.join("moved")).unwrap();
		parent.create_file(b"data").unwrap();
		let desired = CanonicalMetadata::normalize(
			Metadata {
				xattrs: [
					(XattrClass::Logical, &b"binary"[..], &b"\0\xffvalue"[..]),
					(XattrClass::Logical, &b"empty"[..], &b""[..]),
					(XattrClass::Raw, &b"user.raw\xff"[..], &b"native\0raw"[..]),
					(XattrClass::Raw, &b"foreign\xff"[..], &b"retained\0\xff"[..]),
				]
				.into_iter()
				.map(|(class, name, value)| Xattr {
					class,
					name: Cow::Borrowed(name),
					value: Cow::Borrowed(value),
				})
				.collect(),
				..Metadata::default()
			},
			Omit::default(),
		)
		.unwrap();
		let report = xattrs(&file, &desired, 4, 65_536).unwrap();
		assert_ne!(
			report.bits() & (1 << (CompromiseCode::RawXattrPreserved as u8 - 1)),
			0
		);
		for (name, expected) in [
			(&b"user.binary"[..], &b"\0\xffvalue"[..]),
			(&b"user.empty"[..], &b""[..]),
			(&b"user.raw\xff"[..], &b"native\0raw"[..]),
		] {
			let name = CString::new(name).unwrap();
			let mut bytes = [0u8; 64];
			let count = unsafe {
				libc::fgetxattr(
					file.as_raw_fd(),
					name.as_ptr(),
					bytes.as_mut_ptr().cast(),
					bytes.len(),
				)
			};
			assert_eq!(count as usize, expected.len());
			assert_eq!(&bytes[..expected.len()], expected);
		}
		assert!(
			xattr::get(
				&parent.open_regular_file(b"data").unwrap(),
				b"user.binary",
				65_536
			)
			.unwrap()
			.is_none()
		);
		let captured = CanonicalMetadata::normalize(
			Metadata {
				xattrs: linux_transport::capture_xattrs(&file, 4, 65_536).unwrap(),
				..Metadata::default()
			},
			Omit::default(),
		)
		.unwrap();
		assert_eq!(captured, desired);
	}
	#[test]
	fn native_finder_restore_preserves_exact_fields_and_clears_previous_transports() {
		let fixture = Fixture::new();
		let file = Directory::open(&fixture.0)
			.unwrap()
			.create_file(b"data")
			.unwrap();
		let desired = CanonicalMetadata::new(Metadata {
			finder_flags: 0x1234abcd,
			finder_info: Some([0xff; 32]),
			..Metadata::default()
		})
		.unwrap();
		let report = finder(&file, &desired, 65_536).unwrap();
		for code in [
			CompromiseCode::FinderFlagsPreserved,
			CompromiseCode::FinderInfoPreserved,
		] {
			assert_ne!(report.bits() & (1 << (code as u8 - 1)), 0);
		}
		assert_eq!(
			linux_capture::capture_finder(&file, 65_536).unwrap(),
			desired.into_metadata()
		);
		assert_eq!(
			finder(&file, &CanonicalMetadata::default(), 65_536)
				.unwrap()
				.bits(),
			0
		);
		for name in [b"user.difz.bsd-flags".as_slice(), b"user.difz.finder-info"] {
			assert!(xattr::get(&file, name, 65_536).unwrap().is_none());
		}
	}
	#[test]
	fn attribute_and_finder_limits_reject_before_creating_any_transport() {
		let fixture = Fixture::new();
		let file = Directory::open(&fixture.0)
			.unwrap()
			.create_file(b"data")
			.unwrap();
		let desired = CanonicalMetadata::new(Metadata {
			finder_flags: 1,
			..Metadata::default()
		})
		.unwrap();
		assert!(matches!(
			finder(&file, &desired, 19),
			Err(Error::LimitExceeded)
		));
		assert!(matches!(
			xattrs(&file, &CanonicalMetadata::default(), 0, 19),
			Err(Error::LimitExceeded)
		));
		match xattr::list(&file, 65_536, 100) {
			Ok(names) => assert!(!names.iter().any(|name| metadata::is_transport_name(name))),
			Err(Error::Io(error)) => assert_eq!(error.raw_os_error(), Some(libc::ENOTSUP)),
			other => panic!("unexpected readback: {other:?}"),
		}
	}
}
