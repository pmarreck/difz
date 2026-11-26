//! Complete ordinary-file/directory metadata capture for the Linux adapter.
use crate::{EntryInfo, Error, Kind, linux_capture, linux_metadata, linux_transport, sparse};
use difz_core::metadata::{CanonicalMetadata, Family, Metadata, Omit};
use std::{borrow::Cow, fs::File, io};

pub use crate::metadata_limits::Limits;

/// Consume an opened regular file or directory. Omission precedes all family
/// reads. Serialized metadata and native buffers each obey the byte ceiling.
/// Sparse queries may seek the consumed file's shared open-file description.
pub fn capture(
	file: File,
	omit: Omit,
	limits: Limits,
) -> Result<(EntryInfo, CanonicalMetadata<'static>), Error> {
	let before = EntryInfo::for_file(&file)?;
	match before.kind {
		Kind::File | Kind::Directory => {}
		Kind::Symlink | Kind::Other => return Err(Error::WrongKind),
	}
	let mut metadata = Metadata::default();
	let mut native_holes = false;
	for &family in Family::ALL {
		if omit.contains(family) {
			continue;
		}
		match family {
			Family::Xattr => {
				metadata.xattrs = linux_transport::capture_xattrs(
					&file,
					limits.attributes,
					limits.metadata_bytes,
				)?
			}
			Family::Acl => {
				let mut part = linux_capture::capture_acl(&file, limits.metadata_bytes)?;
				metadata.aces = std::mem::take(&mut part.aces);
				metadata.native_acl = part.native_acl.take();
				empty(&part)?;
			}
			Family::Timestamps => metadata.times = linux_metadata::capture_times(&file)?,
			Family::Finder => {
				let mut part = linux_capture::capture_finder(&file, limits.metadata_bytes)?;
				metadata.finder_flags = std::mem::take(&mut part.finder_flags);
				metadata.finder_info = part.finder_info.take();
				empty(&part)?;
			}
			Family::Sparse => {
				if before.kind != Kind::File {
					continue;
				}
				if let Some(bytes) = linux_transport::optional(
					&file,
					b"user.difz.sparse-holes",
					limits.metadata_bytes,
				)? {
					let mut part = CanonicalMetadata::decode(&bytes)
						.map_err(Error::Metadata)?
						.into_metadata();
					metadata.holes = std::mem::take(&mut part.holes);
					empty(&part)?;
					if metadata.holes.len() > limits.extents {
						return Err(Error::LimitExceeded);
					}
				} else {
					native_holes = true;
				}
			}
			Family::Hardlink => {
				if before.kind == Kind::File {
					metadata.hardlink_to =
						linux_capture::capture_hardlink(&file, limits.metadata_bytes)?
							.map(Cow::Owned);
				}
			}
		}
	}
	if native_holes {
		// Keep the original descriptor for identity readback after the scan.
		// This fallible handle duplication shares position; the input is consumed
		// and no payload reads follow it here, so no data buffer needs cloning.
		metadata.holes = sparse::capture(file.try_clone()?, limits.extents)?;
	}
	if EntryInfo::for_file(&file)? != before {
		return Err(io::Error::new(
			io::ErrorKind::InvalidData,
			"object changed during metadata capture",
		)
		.into());
	}
	let canonical = CanonicalMetadata::normalize(metadata, omit).map_err(Error::Metadata)?;
	if canonical.encoded_len().map_err(Error::Metadata)? > limits.metadata_bytes {
		return Err(Error::LimitExceeded);
	}
	Ok((before, canonical))
}
fn empty(value: &Metadata<'_>) -> Result<(), Error> {
	if value.is_empty() {
		Ok(())
	} else {
		Err(Error::Metadata(difz_core::metadata::Error::BadMetadata))
	}
}

/// Capture a link's own families, leaving parent transport merging to the tree
/// adapter. Linux link attributes are read without following its final path.
pub fn capture_symlink(
	reader: &crate::xattr::Symlink<'_>,
	omit: Omit,
	limits: Limits,
) -> Result<CanonicalMetadata<'static>, Error> {
	let mut metadata = Metadata::default();
	for &family in Family::ALL {
		if omit.contains(family) {
			continue;
		}
		match family {
			Family::Xattr => {
				metadata.xattrs = linux_transport::capture_xattrs(
					reader,
					limits.attributes,
					limits.metadata_bytes,
				)?
			}
			Family::Acl => {
				let mut part = linux_capture::capture_acl(reader, limits.metadata_bytes)?;
				metadata.aces = std::mem::take(&mut part.aces);
				metadata.native_acl = part.native_acl.take();
				empty(&part)?;
			}
			Family::Timestamps => {
				metadata.times = linux_metadata::capture_times_for(reader.info(), reader)?
			}
			Family::Finder => {
				let mut part = linux_capture::capture_finder(reader, limits.metadata_bytes)?;
				metadata.finder_flags = std::mem::take(&mut part.finder_flags);
				metadata.finder_info = part.finder_info.take();
				empty(&part)?;
			}
			Family::Sparse | Family::Hardlink => {}
		}
	}
	reader.verify()?;
	let canonical = CanonicalMetadata::normalize(metadata, omit).map_err(Error::Metadata)?;
	if canonical.encoded_len().map_err(Error::Metadata)? > limits.metadata_bytes {
		return Err(Error::LimitExceeded);
	}
	Ok(canonical)
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use std::{ffi::CString, fs, os::fd::AsRawFd};
	#[test]
	fn native_capture_omits_families_before_reading_malformed_transport() {
		let fixture = Fixture::new();
		let path = fixture.0.join("data");
		fs::write(&path, b"payload").unwrap();
		let file = File::open(&path).unwrap();
		for name in [
			"user.difz.native-acl",
			"user.difz.raw-xattrs",
			"user.difz.btime",
		] {
			let name = CString::new(name).unwrap();
			assert_eq!(
				unsafe {
					libc::fsetxattr(
						file.as_raw_fd(),
						name.as_ptr(),
						b"bad".as_ptr().cast(),
						3,
						0,
					)
				},
				0
			);
		}
		let all = Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap();
		let (info, metadata) = capture(File::open(&path).unwrap(), all, Limits::default()).unwrap();
		assert_eq!(info.kind, Kind::File);
		assert!(metadata.metadata().is_empty());
		assert!(
			capture(
				File::open(&path).unwrap(),
				Omit::default(),
				Limits::default()
			)
			.is_err()
		);
	}
	#[test]
	fn ordinary_capture_keeps_native_times_and_bounds_the_canonical_record() {
		let fixture = Fixture::new();
		let path = fixture.0.join("empty");
		fs::write(&path, []).unwrap();
		let (info, metadata) = capture(
			File::open(&path).unwrap(),
			Omit::default(),
			Limits::default(),
		)
		.unwrap();
		assert_eq!(metadata.metadata().times.mtime, Some(info.mtime));
		assert_eq!(metadata.metadata().times.btime, info.birth);
		assert!(metadata.metadata().holes.is_empty());
		let all = Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap();
		assert!(matches!(
			capture(
				File::open(&path).unwrap(),
				all,
				Limits {
					metadata_bytes: 19,
					..Limits::default()
				}
			),
			Err(Error::LimitExceeded)
		));
		let (info, metadata) = capture(
			File::open(&fixture.0).unwrap(),
			Omit::default(),
			Limits::default(),
		)
		.unwrap();
		assert_eq!(info.kind, Kind::Directory);
		assert!(metadata.metadata().holes.is_empty() && metadata.metadata().hardlink_to.is_none());
	}
}
