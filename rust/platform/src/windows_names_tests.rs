use super::*;
use crate::windows::tests::Fixture;
use std::fs;
use windows_sys::Win32::{
	Foundation::{GetHandleInformation, HANDLE_FLAG_INHERIT},
	System::Threading::{GetCurrentProcess, GetProcessHandleCount},
};

#[test]
fn multiple_batches_match_independent_windows_directory_readback() {
	let fixture = Fixture::new();
	for index in 0..600 {
		let name = format!("entry-{index:04}-{}", "x".repeat(60));
		fs::write(fixture.0.join(name), b"").unwrap();
	}
	let root = Directory::open(&fixture.0).unwrap();
	// Compare the standard library's separately implemented native reader.
	// Seed names require multiple 64KiB NT batches even without record padding.
	let mut expected: Vec<Vec<u8>> = fs::read_dir(&fixture.0)
		.unwrap()
		.map(|entry| {
			entry
				.unwrap()
				.file_name()
				.into_string()
				.unwrap()
				.into_bytes()
		})
		.collect();
	assert_eq!(expected.len(), 600);
	assert!(
		expected
			.iter()
			.map(|name| 12 + name.len() * 2)
			.sum::<usize>()
			> 65_536
	);
	let mut actual: Vec<Vec<u8>> = root
		.names(600, 128)
		.unwrap()
		.collect::<Result<_, _>>()
		.unwrap();
	expected.sort();
	actual.sort();
	assert_eq!(actual, expected);
	let mut limited = root.names(599, 128).unwrap();
	for _ in 0..599 {
		assert!(limited.next().unwrap().is_ok());
	}
	assert!(matches!(limited.next(), Some(Err(Error::LimitExceeded))));
	assert!(limited.next().is_none());
}

#[test]
fn independent_streams_preserve_rename_identity_limits_and_handle_ownership() {
	let fixture = Fixture::new();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	for name in ["plain", "caf\u{e9}\u{1f600}"] {
		fs::write(fixture.0.join("selected").join(name), b"").unwrap();
	}
	let root = Directory::open(&fixture.0).unwrap();
	let selected = root.open_directory(b"selected").unwrap();
	fs::rename(fixture.0.join("selected"), fixture.0.join("moved")).unwrap();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	fs::write(fixture.0.join("selected/replacement"), b"").unwrap();
	let mut left = selected.names(2, 128).unwrap();
	let mut right = selected.names(2, 128).unwrap();
	let mut actual = Vec::new();
	for _ in 0..2 {
		let name = left.next().unwrap().unwrap();
		assert_eq!(name, right.next().unwrap().unwrap());
		actual.push(name);
	}
	actual.sort();
	let mut expected = vec![b"plain".to_vec(), "caf\u{e9}\u{1f600}".as_bytes().to_vec()];
	expected.sort();
	assert_eq!(actual, expected);
	assert!(left.next().is_none() && right.next().is_none());
	assert!(left.next().is_none() && right.next().is_none());
	let mut flags = 0;
	assert_ne!(
		unsafe { GetHandleInformation(left.file.as_raw_handle(), &mut flags) },
		0
	);
	assert_eq!(flags & HANDLE_FLAG_INHERIT, 0);

	fs::create_dir(fixture.0.join("unicode")).unwrap();
	fs::write(fixture.0.join("unicode/\u{1f600}"), b"").unwrap();
	let unicode = root.open_directory(b"unicode").unwrap();
	let names: Vec<_> = unicode
		.names(1, 4)
		.unwrap()
		.collect::<Result<_, _>>()
		.unwrap();
	assert_eq!(names, vec!["\u{1f600}".as_bytes().to_vec()]);
	for (count, bytes) in [(1, 3), (0, 4), (1, 0)] {
		let mut stream = unicode.names(count, bytes).unwrap();
		assert!(matches!(stream.next(), Some(Err(Error::LimitExceeded))));
		assert!(stream.next().is_none());
	}
	fs::create_dir(fixture.0.join("empty")).unwrap();
	let mut empty = root.open_directory(b"empty").unwrap().names(0, 0).unwrap();
	assert!(empty.next().is_none() && empty.next().is_none());
	fn count() -> u32 {
		let mut count = 0;
		assert_ne!(
			unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut count) },
			0
		);
		count
	}
	let before = count();
	for _ in 0..32 {
		assert_eq!(
			selected
				.names(2, 128)
				.unwrap()
				.collect::<Result<Vec<_>, _>>()
				.unwrap()
				.len(),
			2
		);
	}
	assert_eq!(count(), before);
}

#[test]
fn malformed_nt_records_and_lossy_unicode_are_rejected() {
	// FILE_NAMES_INFORMATION's documented three-u32 header followed by WCHARs.
	let valid = [0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, b'a', 0];
	for end in 0..valid.len() {
		assert!(record(&valid[..end], 0).is_err());
	}
	let (next, name) = record(&valid, 0).unwrap();
	assert_eq!(next, valid.len());
	assert_eq!(decode_name(name, 1).unwrap(), b"a");
	assert!(record(&valid, usize::MAX).is_err());
	for next in [1u32, 4, 8, 12, 14, 16, u32::MAX] {
		let mut broken = valid;
		broken[..4].copy_from_slice(&next.to_le_bytes());
		assert!(record(&broken, 0).is_err());
	}
	for length in [0u32, 1, 3, 4, u32::MAX] {
		let mut broken = valid;
		broken[8..12].copy_from_slice(&length.to_le_bytes());
		assert!(record(&broken, 0).is_err());
	}
	let mut pair = vec![0; 30];
	pair[..14].copy_from_slice(&valid);
	pair[..4].copy_from_slice(&16u32.to_le_bytes());
	pair[16..].copy_from_slice(&valid);
	pair[28] = b'b';
	let (next, name) = record(&pair, 0).unwrap();
	assert_eq!(next, 16);
	assert_eq!(decode_name(name, 1).unwrap(), b"a");
	let (next, name) = record(&pair, next).unwrap();
	assert_eq!(next, 30);
	assert_eq!(decode_name(name, 1).unwrap(), b"b");
	pair[8..12].copy_from_slice(&6u32.to_le_bytes());
	assert!(
		record(&pair, 0).is_err(),
		"name crossed into the next record"
	);
	for bytes in [b"a".as_slice(), b"\x3d\xd8", b"\x00\xdc", b"\x00\x00"] {
		assert!(matches!(
			decode_name(bytes, 128),
			Err(Error::InvalidBasename)
		));
	}
	assert_eq!(
		decode_name(b"\x3d\xd8\x00\xde", 4).unwrap(),
		"\u{1f600}".as_bytes()
	);
	assert!(matches!(
		decode_name(b"\x3d\xd8\x00\xde", 3),
		Err(Error::LimitExceeded)
	));
}
