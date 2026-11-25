//! Sparse extents through opened regular files, with bounded descriptor storage.
use crate::{EntryInfo, Error, Kind};
use difz_core::metadata::Hole;
use std::{fs::File, io, os::fd::AsRawFd};

/// Consume an independently opened handle. Seeking changes its file position;
/// callers must not pass a duplicated handle whose shared position they need.
/// Work is linear in the number of reported extents, not logical file size.
pub fn capture(file: File, maximum_extents: usize) -> Result<Vec<Hole>, Error> {
	let size = regular_size(&file)?;
	let mut cursor = 0;
	let mut holes = Vec::new();
	while cursor < size {
		let hole = match seek(&file, cursor, libc::SEEK_HOLE) {
			Err(Error::Io(error))
				if matches!(error.raw_os_error(), Some(libc::EINVAL | libc::ENOTSUP)) =>
			{
				return Ok(Vec::new());
			}
			other => match other? {
				Some(value) => value,
				None => break,
			},
		};
		if hole < cursor {
			return Err(invalid("hole seek moved backwards"));
		}
		if hole >= size {
			break;
		}
		let next = seek(&file, hole, libc::SEEK_DATA)?
			.unwrap_or(size)
			.min(size);
		if next <= hole {
			return Err(invalid("data seek did not advance"));
		}
		if holes.len() == maximum_extents {
			return Err(Error::LimitExceeded);
		}
		holes.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
		holes.push(Hole {
			offset: hole,
			length: next - hole,
		});
		cursor = next;
	}
	Ok(holes)
}

/// Deallocate ranges, filling their logical bytes with zero. Validate every
/// range before the first mutation. Native errors remain explicit so a staging
/// adapter can preserve the desired layout in transport after readback.
pub fn punch(file: &File, holes: &[Hole]) -> Result<(), Error> {
	let size = regular_size(file)?;
	for hole in holes {
		if hole.length == 0
			|| hole
				.offset
				.checked_add(hole.length)
				.is_none_or(|end| end > size)
		{
			return Err(invalid("invalid sparse extent"));
		}
	}
	for hole in holes {
		#[cfg(target_os = "linux")]
		// Validated offsets fit off_t. The borrowed writable descriptor is live.
		let result = unsafe {
			libc::fallocate(
				file.as_raw_fd(),
				libc::FALLOC_FL_KEEP_SIZE | libc::FALLOC_FL_PUNCH_HOLE,
				hole.offset as i64,
				hole.length as i64,
			)
		};
		#[cfg(target_os = "macos")]
		let result = {
			#[repr(C)]
			struct Punch {
				flags: u32,
				reserved: u32,
				offset: i64,
				length: i64,
			}
			let range = Punch {
				flags: 0,
				reserved: 0,
				offset: hole.offset as i64,
				length: hole.length as i64,
			};
			// Darwin F_PUNCHHOLE takes this fixed ABI record and does not retain it.
			unsafe { libc::fcntl(file.as_raw_fd(), 99, &range as *const Punch) }
		};
		if result != 0 {
			return Err(io::Error::last_os_error().into());
		}
	}
	Ok(())
}
fn regular_size(file: &File) -> Result<u64, Error> {
	let info = EntryInfo::for_file(file)?;
	if info.kind != Kind::File {
		return Err(Error::WrongKind);
	}
	if info.length > i64::MAX as u64 {
		return Err(Error::LimitExceeded);
	}
	Ok(info.length)
}
fn seek(file: &File, offset: u64, whence: i32) -> Result<Option<u64>, Error> {
	// Callers checked offset against the regular file's signed-length ceiling.
	let result = unsafe { libc::lseek(file.as_raw_fd(), offset as i64, whence) };
	if result >= 0 {
		return Ok(Some(result as u64));
	}
	let error = io::Error::last_os_error();
	if error.raw_os_error() == Some(libc::ENXIO) {
		Ok(None)
	} else {
		Err(error.into())
	}
}
fn invalid(message: &'static str) -> Error {
	io::Error::new(io::ErrorKind::InvalidData, message).into()
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use std::{
		fs::{self, OpenOptions},
		io::{Seek, SeekFrom},
		os::unix::fs::FileExt,
	};
	#[test]
	fn capture_matches_independent_data_first_walk_and_preserves_other_open_positions() {
		let fixture = Fixture::new();
		let path = fixture.0.join("sparse");
		let file = OpenOptions::new()
			.create_new(true)
			.read(true)
			.write(true)
			.open(&path)
			.unwrap();
		file.set_len(96 * 1024).unwrap();
		file.write_all_at(&[0xff; 4096], 8192).unwrap();
		file.write_all_at(&[0x7f; 4096], 80 * 1024).unwrap();
		let probe = File::open(&path).unwrap();
		let mut expected = Vec::new();
		let mut cursor = 0u64;
		let size = 96 * 1024;
		while cursor < size {
			// Independent oracle walks DATA first, then its ending HOLE.
			let data = unsafe { libc::lseek(probe.as_raw_fd(), cursor as i64, libc::SEEK_DATA) };
			let data = if data >= 0 {
				data as u64
			} else {
				let error = io::Error::last_os_error().raw_os_error().unwrap();
				if error == libc::ENXIO {
					size
				} else {
					assert!(matches!(error, libc::EINVAL | libc::ENOTSUP));
					expected.clear();
					break;
				}
			};
			assert!(data >= cursor && data <= size);
			if data > cursor {
				expected.push(Hole {
					offset: cursor,
					length: data - cursor,
				});
			}
			if data == size {
				break;
			}
			let hole = unsafe { libc::lseek(probe.as_raw_fd(), data as i64, libc::SEEK_HOLE) };
			assert!(hole > data as i64);
			cursor = (hole as u64).min(size);
		}
		let mut reader = File::open(&path).unwrap();
		reader.seek(SeekFrom::Start(19)).unwrap();
		let actual = capture(File::open(&path).unwrap(), 128).unwrap();
		assert_eq!(actual, expected);
		assert_eq!(reader.stream_position().unwrap(), 19);
		if !actual.is_empty() {
			assert!(matches!(
				capture(File::open(&path).unwrap(), actual.len() - 1),
				Err(Error::LimitExceeded)
			));
		}
		let bytes = fs::read(&path).unwrap();
		for hole in actual {
			assert!(
				bytes[hole.offset as usize..(hole.offset + hole.length) as usize]
					.iter()
					.all(|b| *b == 0)
			);
		}
	}
	#[test]
	fn punch_checks_every_range_before_mutation_and_reconstructs_zero_bytes() {
		let fixture = Fixture::new();
		let path = fixture.0.join("data");
		fs::write(&path, [0x7f; 32768]).unwrap();
		let file = OpenOptions::new()
			.read(true)
			.write(true)
			.open(&path)
			.unwrap();
		let first = Hole {
			offset: 4096,
			length: 8192,
		};
		for bad in [
			Hole {
				offset: 0,
				length: 0,
			},
			Hole {
				offset: 32768,
				length: 1,
			},
			Hole {
				offset: u64::MAX,
				length: 1,
			},
		] {
			assert!(punch(&file, &[first, bad]).is_err());
			assert_eq!(fs::read(&path).unwrap(), [0x7f; 32768]);
		}
		punch(&file, &[first]).unwrap();
		let mut expected = [0x7f; 32768];
		expected[4096..12288].fill(0);
		assert_eq!(fs::read(&path).unwrap(), expected);
		assert_eq!(file.metadata().unwrap().len(), 32768);
	}
	#[test]
	fn empty_files_and_directory_handles_have_explicit_extent_behavior() {
		let fixture = Fixture::new();
		let path = fixture.0.join("empty");
		fs::write(&path, []).unwrap();
		assert!(capture(File::open(&path).unwrap(), 0).unwrap().is_empty());
		assert!(matches!(
			capture(File::open(&fixture.0).unwrap(), 0),
			Err(Error::WrongKind)
		));
		assert!(punch(&File::open(&path).unwrap(), &[]).is_ok());
	}
}
