use super::{Directory, Error};
use crate::tests::Fixture;
use std::{
	ffi::OsStr,
	fs,
	os::unix::{ffi::OsStrExt, fs::symlink},
};

fn sorted(names: super::Names) -> Vec<Vec<u8>> {
	let mut names = names.collect::<Result<Vec<_>, _>>().unwrap();
	names.sort();
	names
}

#[test]
fn directory_names_match_independent_readback_and_preserve_raw_bytes() {
	let fixture = Fixture::new();
	for name in [b"a".as_slice(), b".hidden", b"raw\xff", "é".as_bytes()] {
		fs::write(fixture.0.join(OsStr::from_bytes(name)), b"bytes").unwrap();
	}
	fs::create_dir(fixture.0.join("sub")).unwrap();
	fs::write(fixture.0.join("sub/nested"), b"not a direct child").unwrap();
	symlink("missing", fixture.0.join("link")).unwrap();
	let mut expected: Vec<Vec<u8>> = fs::read_dir(&fixture.0)
		.unwrap()
		.map(|entry| entry.unwrap().file_name().as_bytes().to_vec())
		.collect();
	expected.sort();
	let root = Directory::open(&fixture.0).unwrap();
	assert_eq!(sorted(root.names(6, 255).unwrap()), expected);
}

#[test]
fn directory_name_limits_are_exact_and_errors_finish_the_stream() {
	let fixture = Fixture::new();
	let root = Directory::open(&fixture.0).unwrap();
	let mut empty = root.names(0, 0).unwrap();
	// Seed a real libc error so an unchanged errno cannot turn EOF into IO.
	assert_eq!(unsafe { libc::close(-1) }, -1);
	assert!(empty.next().is_none());
	for name in ["aa", "bb"] {
		fs::write(fixture.0.join(name), b"").unwrap();
	}
	assert_eq!(
		sorted(root.names(2, 2).unwrap()),
		[b"aa".to_vec(), b"bb".to_vec()]
	);
	let mut limited = root.names(1, 2).unwrap();
	assert!(limited.next().unwrap().is_ok());
	assert!(matches!(limited.next(), Some(Err(Error::LimitExceeded))));
	assert!(limited.next().is_none());
	for (count, bytes) in [(0, 2), (2, 1), (2, 0)] {
		let mut names = root.names(count, bytes).unwrap();
		assert!(matches!(names.next(), Some(Err(Error::LimitExceeded))));
		assert!(names.next().is_none());
	}
}

#[test]
fn directory_streams_have_independent_offsets_and_keep_the_opened_identity() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	for name in ["one", "two"] {
		fs::write(fixture.0.join("selected").join(name), b"").unwrap();
	}
	fs::write(outside.0.join("outside"), b"").unwrap();
	let root = Directory::open(&fixture.0.join("selected")).unwrap();
	let mut first = root.names(2, 255).unwrap();
	let second = root.names(2, 255).unwrap();
	let one = first.next().unwrap().unwrap();
	fs::rename(fixture.0.join("selected"), fixture.0.join("moved")).unwrap();
	symlink(&outside.0, fixture.0.join("selected")).unwrap();
	drop(root);
	let expected = [b"one".to_vec(), b"two".to_vec()];
	assert_eq!(sorted(second), expected);
	let mut resumed = vec![one];
	resumed.extend(first.collect::<Result<Vec<_>, _>>().unwrap());
	resumed.sort();
	assert_eq!(resumed, expected);
}

#[cfg(target_os = "linux")]
#[test]
fn directory_stream_descriptors_close_after_completion_error_and_early_drop() {
	fn count() -> usize {
		fs::read_dir("/proc/self/fd").unwrap().count()
	}
	let fixture = Fixture::new();
	fs::write(fixture.0.join("entry"), b"").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	let pinned_path = fs::canonicalize(&fixture.0).unwrap();
	let before = count();
	for _ in 0..32 {
		assert_eq!(sorted(root.names(1, 255).unwrap()), [b"entry".to_vec()]);
		let mut partial = root.names(1, 255).unwrap();
		assert!(partial.next().unwrap().is_ok());
		let mut pinned = 0;
		for entry in fs::read_dir("/proc/self/fd").unwrap() {
			let entry = entry.unwrap();
			if fs::read_link(entry.path()).ok().as_ref() == Some(&pinned_path) {
				let fd: libc::c_int = entry.file_name().to_str().unwrap().parse().unwrap();
				// Query live kernel flags without relying on the stream's fields.
				let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
				assert!(flags >= 0);
				assert_ne!(flags & libc::FD_CLOEXEC, 0);
				pinned += 1;
			}
		}
		assert_eq!(pinned, 2);
		drop(partial);
		let mut failed = root.names(0, 255).unwrap();
		assert!(failed.next().unwrap().is_err());
	}
	assert_eq!(count(), before);
}
