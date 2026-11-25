//! Timestamp restoration with canonical readback on opened Linux objects.
use crate::{EntryInfo, Error, Kind, xattr};
use difz_core::metadata::{self, CompromiseCode, ModificationOverride, RestoreReport, Times};
use std::{fs::File, io, os::fd::AsRawFd};

/// Set modification time where possible and preserve exact absence/coarse
/// values in transport. Access time is outside the native snapshot profile.
/// Validate the entire request before changing either the file or transport.
pub fn restore(file: &File, desired: Times) -> Result<RestoreReport, Error> {
	let Times {
		mtime,
		atime,
		btime,
	} = desired;
	for time in [mtime, atime, btime].into_iter().flatten() {
		if time.nsec >= 1_000_000_000 {
			return Err(Error::Metadata(metadata::Error::InvalidNsec));
		}
	}
	if atime.is_some() {
		return Err(Error::Io(io::Error::new(
			io::ErrorKind::Unsupported,
			"access time is outside the native snapshot profile",
		)));
	}
	match EntryInfo::for_file(file)?.kind {
		Kind::File | Kind::Directory => {}
		Kind::Symlink | Kind::Other => return Err(Error::WrongKind),
	}
	if let Some(time) = mtime {
		let values = [
			libc::timespec {
				tv_sec: 0,
				tv_nsec: libc::UTIME_OMIT,
			},
			libc::timespec {
				tv_sec: time.sec,
				tv_nsec: i64::from(time.nsec),
			},
		];
		// Borrowed descriptor and initialized timespec array remain live. The
		// kernel copies them synchronously; access time is explicitly unchanged.
		// Native restoration is best effort. Readback below decides whether
		// rejected or clamped values need canonical transport and a warning.
		let _ = unsafe { libc::futimens(file.as_raw_fd(), values.as_ptr()) };
	}
	let actual = EntryInfo::for_file(file)?;
	let mut report = RestoreReport::default();
	if actual.birth == btime {
		remove(file, b"user.difz.btime")?;
	} else {
		let bytes = metadata::encode_time_override(btime).map_err(Error::Metadata)?;
		xattr::set(file, b"user.difz.btime", bytes.as_bytes())?;
		report.add(CompromiseCode::BirthTimePreserved);
	}
	if Some(actual.mtime) == mtime {
		remove(file, b"user.difz.mtime")?;
	} else {
		let bytes = metadata::encode_modification_override(ModificationOverride {
			original: mtime,
			observed: actual.mtime,
		})
		.map_err(Error::Metadata)?;
		xattr::set(file, b"user.difz.mtime", bytes.as_bytes())?;
		report.add(CompromiseCode::ModificationTimePreserved);
	}
	if crate::linux_metadata::capture_times(file)? != desired {
		return Err(
			io::Error::new(io::ErrorKind::InvalidData, "timestamp readback mismatch").into(),
		);
	}
	Ok(report)
}
fn remove(file: &File, name: &[u8]) -> Result<(), Error> {
	match xattr::remove(file, name) {
		Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOTSUP) => Ok(()),
		other => other.map(|_| ()),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{linux_metadata::capture_times, tests::Fixture};
	use difz_core::metadata::Time;
	use std::{
		fs,
		time::{Duration, UNIX_EPOCH},
	};
	#[test]
	fn native_timestamp_restore_uses_open_identity_and_exact_creation_transport() {
		let fixture = Fixture::new();
		fs::write(fixture.0.join("data"), b"original").unwrap();
		let file = File::open(fixture.0.join("data")).unwrap();
		fs::rename(fixture.0.join("data"), fixture.0.join("moved")).unwrap();
		fs::write(fixture.0.join("data"), b"replacement").unwrap();
		let desired = Times {
			mtime: Some(Time { sec: -7, nsec: 42 }),
			atime: None,
			btime: Some(Time { sec: -13, nsec: 11 }),
		};
		let report = restore(&file, desired).unwrap();
		assert_ne!(
			report.bits() & (1 << (CompromiseCode::BirthTimePreserved as u8 - 1)),
			0
		);
		assert_eq!(
			file.metadata().unwrap().modified().unwrap(),
			UNIX_EPOCH - Duration::new(6, 999_999_958)
		);
		assert_eq!(capture_times(&file).unwrap(), desired);
		let mut bytes = [0u8; 32];
		// Independent kernel readback of the fixed 13-byte timestamp grammar.
		let count = unsafe {
			libc::fgetxattr(
				file.as_raw_fd(),
				c"user.difz.btime".as_ptr(),
				bytes.as_mut_ptr().cast(),
				bytes.len(),
			)
		};
		let mut expected = vec![1];
		expected.extend_from_slice(&(-13i64).to_le_bytes());
		expected.extend_from_slice(&11u32.to_le_bytes());
		assert_eq!(count, 13);
		assert_eq!(&bytes[..13], expected);
		assert_ne!(
			File::open(fixture.0.join("data"))
				.unwrap()
				.metadata()
				.unwrap()
				.modified()
				.unwrap(),
			UNIX_EPOCH - Duration::new(6, 999_999_958)
		);
	}
	#[test]
	fn native_absent_timestamp_restore_has_a_stale_witness_and_removes_old_overrides() {
		let fixture = Fixture::new();
		fs::write(fixture.0.join("data"), b"").unwrap();
		let file = File::open(fixture.0.join("data")).unwrap();
		let report = restore(&file, Times::default()).unwrap();
		assert_ne!(
			report.bits() & (1 << (CompromiseCode::ModificationTimePreserved as u8 - 1)),
			0
		);
		assert_eq!(capture_times(&file).unwrap(), Times::default());
		file.set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH + Duration::new(42, 7)))
			.unwrap();
		assert_eq!(
			capture_times(&file).unwrap().mtime,
			Some(Time { sec: 42, nsec: 7 })
		);
		let native = EntryInfo::for_file(&file).unwrap();
		restore(
			&file,
			Times {
				mtime: Some(native.mtime),
				atime: None,
				btime: native.birth,
			},
		)
		.unwrap();
		for name in [b"user.difz.btime".as_slice(), b"user.difz.mtime"] {
			assert!(xattr::get(&file, name, 32).unwrap().is_none());
		}
		for sec in [i64::MIN, i64::MAX] {
			let requested = Times {
				mtime: Some(Time { sec, nsec: 42 }),
				atime: None,
				btime: None,
			};
			restore(&file, requested).unwrap();
			assert_eq!(capture_times(&file).unwrap(), requested);
		}
	}
	#[test]
	fn invalid_or_unsupported_times_fail_before_native_or_transport_mutation() {
		let fixture = Fixture::new();
		fs::write(fixture.0.join("data"), b"").unwrap();
		let file = File::open(fixture.0.join("data")).unwrap();
		let original = file.metadata().unwrap().modified().unwrap();
		for desired in [
			Times {
				mtime: Some(Time { sec: 1, nsec: 0 }),
				btime: Some(Time {
					sec: 0,
					nsec: 1_000_000_000,
				}),
				atime: None,
			},
			Times {
				mtime: Some(Time { sec: 1, nsec: 0 }),
				atime: Some(Time { sec: 0, nsec: 0 }),
				btime: None,
			},
		] {
			assert!(restore(&file, desired).is_err());
			assert_eq!(file.metadata().unwrap().modified().unwrap(), original);
			for name in [b"user.difz.btime".as_slice(), b"user.difz.mtime"] {
				match xattr::get(&file, name, 32) {
					Ok(value) => assert!(value.is_none()),
					Err(Error::Io(error)) => assert_eq!(error.raw_os_error(), Some(libc::ENOTSUP)),
					Err(error) => panic!("unexpected attribute error: {error:?}"),
				}
			}
		}
	}
}
