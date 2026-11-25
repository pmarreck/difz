//! Sparse restoration preserves canonical extents when native granularity differs.
use crate::{EntryInfo, Error, Kind, sparse, xattr};
use difz_core::metadata::{CanonicalMetadata, CompromiseCode, Family, Omit, RestoreReport};
use std::{
	fs::File,
	io::{self, Seek, SeekFrom},
	os::unix::fs::FileExt,
};

/// The caller owns a completed staging file. Validate every range and its
/// zero bytes before any native punch, which must never change payload bytes.
/// Restore its shared file position after the native hole scan. Timestamp
/// restoration follows this operation, since a successful punch may change it.
pub fn restore(
	file: &mut File,
	desired: &CanonicalMetadata<'_>,
	maximum_extents: usize,
	maximum_bytes: usize,
) -> Result<RestoreReport, Error> {
	let info = EntryInfo::for_file(file)?;
	if info.kind != Kind::File {
		return Err(Error::WrongKind);
	}
	let holes = &desired.metadata().holes;
	if holes.len() > maximum_extents {
		return Err(Error::LimitExceeded);
	}
	let excluded = Family::ALL
		.iter()
		.filter(|&&family| family != Family::Sparse)
		.fold(0, |bits, family| bits | family.bit());
	let desired = desired
		.borrowing_omitting(Omit::from_bits(excluded).map_err(Error::Metadata)?)
		.map_err(Error::Metadata)?;
	if desired.encoded_len().map_err(Error::Metadata)? > maximum_bytes {
		return Err(Error::LimitExceeded);
	}
	let mut buffer = [0u8; 65_536];
	for hole in holes {
		let end = hole
			.offset
			.checked_add(hole.length)
			.filter(|&end| end <= info.length)
			.ok_or_else(invalid)?;
		let mut position = hole.offset;
		while position < end {
			let count = (end - position).min(buffer.len() as u64) as usize;
			let bytes = &mut buffer[..count];
			file.read_exact_at(bytes, position)?;
			if bytes.iter().any(|&byte| byte != 0) {
				return Err(invalid());
			}
			position += count as u64;
		}
	}
	// A partial native punch remains payload-safe because all regions were
	// validated as zero. Canonical readback decides whether transport is needed.
	match sparse::punch(file, holes) {
		Ok(()) | Err(Error::Io(_)) => {}
		Err(error) => return Err(error),
	}
	let position = file.stream_position()?;
	// A duplicate retains ownership through the consuming scan. It shares the
	// open-file position, restored even if the scan returns an error.
	let native = sparse::capture(file.try_clone()?, maximum_extents);
	file.seek(SeekFrom::Start(position))?;
	let native = native?;
	let mut report = RestoreReport::default();
	if native == *holes {
		match xattr::remove(file, b"user.difz.sparse-holes") {
			Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOTSUP) => {}
			result => {
				result?;
			}
		}
	} else {
		let bytes = desired.encode().map_err(Error::Metadata)?;
		xattr::set(file, b"user.difz.sparse-holes", &bytes)?;
		if xattr::get(file, b"user.difz.sparse-holes", bytes.len())?.as_deref()
			!= Some(bytes.as_slice())
		{
			return Err(io::Error::new(
				io::ErrorKind::InvalidData,
				"sparse transport readback mismatch",
			)
			.into());
		}
		report.add(CompromiseCode::SparsePreserved);
	}
	Ok(report)
}
fn invalid() -> Error {
	io::Error::new(
		io::ErrorKind::InvalidInput,
		"sparse extent is outside the file or contains nonzero data",
	)
	.into()
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{
		Directory,
		linux_snapshot_metadata::{self, Limits},
		tests::Fixture,
	};
	use difz_core::metadata::{Hole, Metadata};
	use std::io::{Read, Write};
	#[test]
	fn native_sparse_restore_preserves_unaligned_canonical_extent_without_changing_bytes_or_position()
	 {
		let fixture = Fixture::new();
		let mut file = Directory::open(&fixture.0)
			.unwrap()
			.create_file(b"data")
			.unwrap();
		let mut payload = vec![0u8; 8192];
		payload[4096..].fill(0x5a);
		file.write_all(&payload).unwrap();
		file.seek(SeekFrom::Start(73)).unwrap();
		let desired = CanonicalMetadata::new(Metadata {
			holes: vec![Hole {
				offset: 1,
				length: 1,
			}],
			..Metadata::default()
		})
		.unwrap();
		let report = restore(&mut file, &desired, 1, 65_536).unwrap();
		assert_ne!(
			report.bits() & (1 << (CompromiseCode::SparsePreserved as u8 - 1)),
			0
		);
		assert_eq!(file.stream_position().unwrap(), 73);
		let omit = Omit::parse(b"xattr,acl,timestamps,finder,hardlink").unwrap();
		assert_eq!(
			linux_snapshot_metadata::capture(file.try_clone().unwrap(), omit, Limits::default())
				.unwrap()
				.1,
			desired
		);
		file.rewind().unwrap();
		let mut readback = Vec::new();
		file.read_to_end(&mut readback).unwrap();
		assert_eq!(readback, payload);
	}
	#[test]
	fn sparse_restore_validates_all_extents_and_limits_before_the_first_native_effect() {
		let fixture = Fixture::new();
		let mut file = Directory::open(&fixture.0)
			.unwrap()
			.create_file(b"data")
			.unwrap();
		let mut payload = vec![0u8; 16384];
		payload[12288..].fill(1);
		file.write_all(&payload).unwrap();
		let before = sparse::capture(file.try_clone().unwrap(), 100).unwrap();
		let desired = CanonicalMetadata::new(Metadata {
			holes: vec![
				Hole {
					offset: 0,
					length: 4096,
				},
				Hole {
					offset: 12288,
					length: 4096,
				},
			],
			..Metadata::default()
		})
		.unwrap();
		assert!(restore(&mut file, &desired, 2, 65_536).is_err());
		assert_eq!(
			sparse::capture(file.try_clone().unwrap(), 100).unwrap(),
			before
		);
		assert!(matches!(
			restore(&mut file, &desired, 1, 65_536),
			Err(Error::LimitExceeded)
		));
		assert!(matches!(
			restore(&mut file, &CanonicalMetadata::default(), 0, 19),
			Err(Error::LimitExceeded)
		));
		file.rewind().unwrap();
		let mut readback = Vec::new();
		file.read_to_end(&mut readback).unwrap();
		assert_eq!(readback, payload);
	}
}
