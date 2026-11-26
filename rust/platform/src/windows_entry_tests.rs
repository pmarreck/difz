use super::*;
use crate::windows::tests::Fixture;
use std::{fs, ptr};
use windows_sys::Win32::Storage::FileSystem::{GetFileTime, SetFileTime};

#[test]
fn native_entry_queries_preserve_hardlink_identity_and_exact_timestamps() {
	let fixture = Fixture::new();
	fs::create_dir(fixture.0.join("sub")).unwrap();
	fs::write(fixture.0.join("data"), b"\0\xffbytes").unwrap();
	fs::hard_link(fixture.0.join("data"), fixture.0.join("alias")).unwrap();
	fs::copy(fixture.0.join("data"), fixture.0.join("copy")).unwrap();
	let writer = fs::OpenOptions::new()
		.read(true)
		.write(true)
		.open(fixture.0.join("data"))
		.unwrap();
	let birth_ticks = 116_444_736_012_345_678u64;
	let mtime_ticks = 116_444_735_999_999_999u64;
	let birth = FILETIME {
		dwLowDateTime: birth_ticks as u32,
		dwHighDateTime: (birth_ticks >> 32) as u32,
	};
	let mtime = FILETIME {
		dwLowDateTime: mtime_ticks as u32,
		dwHighDateTime: (mtime_ticks >> 32) as u32,
	};
	// Native setters supply an independent fixture, including one tick before
	// the Unix epoch. Read back raw FILETIME words before judging conversion.
	assert_ne!(
		unsafe { SetFileTime(writer.as_raw_handle(), &birth, ptr::null(), &mtime) },
		0
	);
	let mut actual_birth = FILETIME::default();
	let mut actual_mtime = FILETIME::default();
	assert_ne!(
		unsafe {
			GetFileTime(
				writer.as_raw_handle(),
				&mut actual_birth,
				ptr::null_mut(),
				&mut actual_mtime,
			)
		},
		0
	);
	// Birth-time setting is a separate restore capability. Wine 11 ignores
	// CreationTime here, so judge the reader against the independent native
	// getter's actual value, rather than pretending the requested value landed.
	assert_eq!(
		(actual_mtime.dwHighDateTime, actual_mtime.dwLowDateTime),
		(mtime.dwHighDateTime, mtime.dwLowDateTime)
	);
	let root = Directory::open(&fixture.0).unwrap();
	let info = root.inspect(b"data").unwrap();
	assert_eq!(info.kind, Kind::File);
	assert_eq!(info.mode.bits(), 0o644);
	assert_eq!(info.length, 7);
	assert_eq!(
		info.mtime,
		Time {
			sec: -1,
			nsec: 999_999_900
		}
	);
	let captured_birth = info.birth.unwrap();
	assert_eq!(
		i128::from(captured_birth.sec) * 10_000_000
			+ i128::from(captured_birth.nsec / 100)
			+ 116_444_736_000_000_000,
		i128::from(
			(u64::from(actual_birth.dwHighDateTime) << 32) | u64::from(actual_birth.dwLowDateTime)
		)
	);
	let alias = root.inspect(b"alias").unwrap();
	assert_eq!(info.identity, alias.identity);
	assert_eq!(info.mtime, alias.mtime);
	assert_ne!(info.identity, root.inspect(b"copy").unwrap().identity);
	let sub = root.inspect(b"sub").unwrap();
	assert_eq!(sub.kind, Kind::Directory);
	assert_eq!(sub.mode.bits(), 0o755);
	assert_eq!(
		sub.identity,
		root.open_directory(b"sub")
			.unwrap()
			.inspect_self()
			.unwrap()
			.identity
	);
	assert_eq!(root.inspect_self().unwrap().kind, Kind::Directory);
	let opened = root.open_regular_file(b"data").unwrap();
	assert_eq!(EntryInfo::for_file(&opened).unwrap(), info);
	fs::rename(fixture.0.join("data"), fixture.0.join("moved")).unwrap();
	fs::write(fixture.0.join("data"), b"replacement").unwrap();
	assert_eq!(
		EntryInfo::for_file(&opened).unwrap().identity,
		info.identity
	);
	assert_ne!(root.inspect(b"data").unwrap().identity, info.identity);
}

#[test]
fn complete_file_ids_round_trip_every_bit_without_narrowing() {
	for bit in 0..128 {
		let mut id = FILE_ID_INFO::default();
		id.VolumeSerialNumber = u64::MAX;
		id.FileId.Identifier[bit / 8] = 1 << (bit % 8);
		let actual = identity(&id);
		assert_eq!(actual.device, u64::MAX);
		assert_eq!(actual.inode.to_le_bytes(), id.FileId.Identifier);
	}
	// An inverse expressed in the format's signed seconds checks epoch/sign
	// boundaries independently of the adapter's quotient/remainder split.
	for ticks in [
		0,
		1,
		116_444_735_999_999_999,
		116_444_736_000_000_000,
		116_444_736_000_000_001,
		u64::MAX,
	] {
		let actual = timestamp(FILETIME {
			dwLowDateTime: ticks as u32,
			dwHighDateTime: (ticks >> 32) as u32,
		});
		assert!(actual.nsec < 1_000_000_000 && actual.nsec % 100 == 0);
		assert_eq!(
			i128::from(actual.sec) * 10_000_000
				+ i128::from(actual.nsec / 100)
				+ 116_444_736_000_000_000,
			i128::from(ticks)
		);
	}
}
