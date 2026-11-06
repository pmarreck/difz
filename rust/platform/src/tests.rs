use super::*;
use std::{
	fs,
	io::Read,
	os::unix::fs::symlink,
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
};
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
pub(crate) struct Fixture(pub(crate) PathBuf);
impl Fixture {
	pub(crate) fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"difz-directory-capability-{}-{}",
			std::process::id(),
			SEQUENCE.fetch_add(1, Ordering::Relaxed)
		));
		fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Fixture {
	fn drop(&mut self) {
		fs::remove_dir_all(&self.0).unwrap();
	}
}
fn contents(mut file: File) -> Vec<u8> {
	let mut bytes = Vec::new();
	file.read_to_end(&mut bytes).unwrap();
	bytes
}

#[test]
fn regular_and_directory_opens_classify_real_entries_and_binary_data() {
	let fixture = Fixture::new();
	fs::create_dir(fixture.0.join("sub")).unwrap();
	fs::write(fixture.0.join("sub/data"), b"\0\xffbytes").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	let sub = root.open_directory(b"sub").unwrap();
	assert_eq!(
		contents(sub.open_regular_file(b"data").unwrap()),
		b"\0\xffbytes"
	);
	assert!(root.open_regular_file(b"sub").is_err());
	assert!(sub.open_directory(b"data").is_err());
	assert!(root.open_regular_file(b"missing").is_err());
}
#[test]
fn opened_directory_identity_survives_rename_and_path_replacement() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	fs::write(fixture.0.join("selected/data"), b"original").unwrap();
	fs::write(outside.0.join("data"), b"outside").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	let selected = root.open_directory(b"selected").unwrap();
	fs::rename(fixture.0.join("selected"), fixture.0.join("moved")).unwrap();
	symlink(&outside.0, fixture.0.join("selected")).unwrap();
	assert_eq!(
		contents(selected.open_regular_file(b"data").unwrap()),
		b"original"
	);
	assert!(root.open_directory(b"selected").is_err());
	assert!(Directory::open(&fixture.0.join("selected")).is_err());
	assert_eq!(fs::read(outside.0.join("data")).unwrap(), b"outside");
}
#[test]
fn symlink_and_fifo_entries_are_rejected_without_following_or_blocking() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::write(outside.0.join("secret"), b"outside").unwrap();
	symlink(outside.0.join("secret"), fixture.0.join("link")).unwrap();
	let fifo = fixture.0.join("fifo");
	use std::os::unix::ffi::OsStrExt;
	let path = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
	// Test-owned path in the isolated scratch directory; the OS borrows it.
	assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
	let root = Directory::open(&fixture.0).unwrap();
	assert!(root.open_regular_file(b"link").is_err());
	assert!(matches!(
		root.open_regular_file(b"fifo"),
		Err(Error::WrongKind)
	));
}
#[test]
fn basename_grammar_rejects_paths_and_nuls_before_any_child_open() {
	let fixture = Fixture::new();
	let root = Directory::open(&fixture.0).unwrap();
	for name in [
		b"".as_slice(),
		b".",
		b"..",
		b"a/b",
		b"a\\b",
		b"a\0b",
		b"C:drive",
		b"\xff",
	] {
		assert!(
			matches!(root.open_directory(name), Err(Error::InvalidBasename)),
			"{name:?}"
		);
		assert!(
			matches!(root.open_regular_file(name), Err(Error::InvalidBasename)),
			"{name:?}"
		);
	}
}

#[cfg(target_os = "linux")]
#[test]
fn kernel_readback_confirms_close_on_exec_and_no_descriptor_leak() {
	use std::os::fd::AsRawFd;
	fn count() -> usize {
		fs::read_dir("/proc/self/fd").unwrap().count()
	}
	let fixture = Fixture::new();
	fs::write(fixture.0.join("data"), b"data").unwrap();
	fs::create_dir(fixture.0.join("sub")).unwrap();
	let before = count();
	for _ in 0..32 {
		let root = Directory::open(&fixture.0).unwrap();
		let file = root.open_regular_file(b"data").unwrap();
		// F_GETFD reads the kernel flag of this live, borrowed file descriptor.
		let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFD) };
		assert!(flags >= 0);
		assert_ne!(flags & libc::FD_CLOEXEC, 0);
		assert!(root.open_regular_file(b"sub").is_err());
		assert!(root.open_directory(b"missing").is_err());
	}
	assert_eq!(count(), before);
}

#[test]
fn regular_file_reads_preserve_binary_bytes_and_exact_zero_or_size_limits() {
	let fixture = Fixture::new();
	fs::write(fixture.0.join("data"), b"\0\xffbytes").unwrap();
	fs::write(fixture.0.join("empty"), b"").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	assert!(matches!(
		root.read_file(b"data", 6),
		Err(Error::LimitExceeded)
	));
	assert!(matches!(
		root.read_file(b"data", 0),
		Err(Error::LimitExceeded)
	));
	assert_eq!(root.read_file(b"data", 7).unwrap(), b"\0\xffbytes");
	assert_eq!(root.read_file(b"empty", 0).unwrap(), b"");
}

#[test]
fn injected_reader_proves_bounded_requests_interrupt_retry_and_error_handling() {
	struct Recording {
		bytes: &'static [u8],
		requests: Vec<usize>,
		interrupt: bool,
	}
	impl Read for Recording {
		fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
			self.requests.push(output.len());
			if self.interrupt {
				self.interrupt = false;
				return Err(io::ErrorKind::Interrupted.into());
			}
			let count = output.len().min(self.bytes.len());
			output[..count].copy_from_slice(&self.bytes[..count]);
			self.bytes = &self.bytes[count..];
			Ok(count)
		}
	}
	let mut reader = Recording {
		bytes: b"0123456789",
		requests: vec![],
		interrupt: true,
	};
	assert!(matches!(
		read_limited(&mut reader, 4),
		Err(Error::LimitExceeded)
	));
	assert_eq!(reader.requests, vec![5, 5]);
	assert_eq!(reader.bytes, b"56789");
	let mut reader = Recording {
		bytes: b"\0\xff",
		requests: vec![],
		interrupt: true,
	};
	assert_eq!(read_limited(&mut reader, 2).unwrap(), b"\0\xff");
	assert_eq!(reader.requests, vec![3, 3, 1]);
	struct Broken;
	impl Read for Broken {
		fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
			Ok(usize::MAX)
		}
	}
	assert!(matches!(read_limited(&mut Broken, 4), Err(Error::Io(_))));
	struct Failed;
	impl Read for Failed {
		fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
			Err(io::ErrorKind::PermissionDenied.into())
		}
	}
	assert!(
		matches!(read_limited(&mut Failed,4),Err(Error::Io(error)) if error.kind()==io::ErrorKind::PermissionDenied)
	);
}

#[test]
fn no_follow_entry_inspection_matches_independent_kernel_metadata() {
	use std::os::unix::fs::{MetadataExt, PermissionsExt};
	use std::os::unix::net::UnixListener;
	let fixture = Fixture::new();
	fs::write(fixture.0.join("data"), b"\0\xffdata").unwrap();
	fs::set_permissions(fixture.0.join("data"), fs::Permissions::from_mode(0o1640)).unwrap();
	fs::hard_link(fixture.0.join("data"), fixture.0.join("alias")).unwrap();
	fs::create_dir(fixture.0.join("sub")).unwrap();
	symlink("missing", fixture.0.join("link")).unwrap();
	let _socket = UnixListener::bind(fixture.0.join("socket")).unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	for (name, kind) in [
		("data", Kind::File),
		("alias", Kind::File),
		("sub", Kind::Directory),
		("link", Kind::Symlink),
		("socket", Kind::Other),
	] {
		let expected = fs::symlink_metadata(fixture.0.join(name)).unwrap();
		let actual = root.inspect(name.as_bytes()).unwrap();
		assert_eq!(actual.kind, kind);
		assert_eq!(actual.length, expected.len());
		assert_eq!(
			actual.identity,
			Identity {
				device: expected.dev(),
				inode: expected.ino()
			}
		);
		assert_eq!(
			actual.mode.bits(),
			if kind == Kind::Symlink {
				0o777
			} else {
				(expected.mode() & 0o777) as u16
			}
		);
	}
	assert_eq!(
		root.inspect(b"data").unwrap().identity,
		root.inspect(b"alias").unwrap().identity
	);
	assert!(root.inspect(b"missing").is_err());
}

#[test]
fn symlink_reads_are_binary_bounded_and_detect_buffer_truncation() {
	use std::{ffi::OsStr, os::unix::ffi::OsStrExt};
	let fixture = Fixture::new();
	let root = Directory::open(&fixture.0).unwrap();
	symlink(OsStr::from_bytes(b"raw\xff"), fixture.0.join("binary")).unwrap();
	let long = "a".repeat(300);
	symlink(&long, fixture.0.join("long")).unwrap();
	fs::write(fixture.0.join("regular"), b"contents").unwrap();
	fs::create_dir(fixture.0.join("directory")).unwrap();
	assert_eq!(root.read_symlink(b"binary", 4).unwrap(), b"raw\xff");
	assert!(matches!(
		root.read_symlink(b"binary", 3),
		Err(Error::LimitExceeded)
	));
	assert!(matches!(
		root.read_symlink(b"binary", 0),
		Err(Error::LimitExceeded)
	));
	assert_eq!(root.read_symlink(b"long", 300).unwrap(), long.as_bytes());
	assert!(matches!(
		root.read_symlink(b"long", 299),
		Err(Error::LimitExceeded)
	));
	for name in [b"regular".as_slice(), b"directory", b"missing"] {
		assert!(matches!(root.read_symlink(name, 1024), Err(Error::Io(_))));
	}
	assert!(matches!(
		root.read_symlink(b"binary", usize::MAX),
		Err(Error::LimitExceeded)
	));
	for name in [b"".as_slice(), b"a/b", b"a\0b", b"..", b"\xff"] {
		assert!(matches!(root.inspect(name), Err(Error::InvalidBasename)));
		assert!(matches!(
			root.read_symlink(name, 1024),
			Err(Error::InvalidBasename)
		));
	}
}

#[test]
fn entry_inspection_and_symlink_reads_keep_the_opened_parent_identity() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	fs::write(fixture.0.join("selected/data"), b"original").unwrap();
	symlink("old", fixture.0.join("selected/link")).unwrap();
	fs::write(outside.0.join("data"), b"outside").unwrap();
	symlink("new", outside.0.join("link")).unwrap();
	let selected = Directory::open(&fixture.0.join("selected")).unwrap();
	let original = selected.inspect(b"data").unwrap();
	fs::rename(fixture.0.join("selected"), fixture.0.join("moved")).unwrap();
	symlink(&outside.0, fixture.0.join("selected")).unwrap();
	assert_eq!(selected.inspect(b"data").unwrap(), original);
	assert_eq!(selected.read_symlink(b"link", 3).unwrap(), b"old");
}

#[test]
fn entry_times_match_independent_metadata_at_negative_seconds_and_nanosecond_precision() {
	use std::{
		fs::FileTimes,
		os::unix::fs::MetadataExt,
		time::{Duration, SystemTime},
	};
	let fixture = Fixture::new();
	let path = fixture.0.join("data");
	fs::write(&path, b"bytes").unwrap();
	let file = OpenOptions::new().write(true).open(&path).unwrap();
	let time = SystemTime::UNIX_EPOCH - Duration::new(10, 123_456_789);
	file.set_times(FileTimes::new().set_modified(time)).unwrap();
	let expected = fs::symlink_metadata(&path).unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	let actual = root.inspect(b"data").unwrap();
	assert_eq!(
		actual.mtime,
		difz_core::metadata::Time {
			sec: -11,
			nsec: 876_543_211
		}
	);
	assert_eq!(actual.mtime.sec, expected.mtime());
	assert_eq!(i64::from(actual.mtime.nsec), expected.mtime_nsec());
	let expected_birth = expected.created().ok().map(|time| {
		let value = time.duration_since(SystemTime::UNIX_EPOCH).unwrap();
		difz_core::metadata::Time {
			sec: value.as_secs() as i64,
			nsec: value.subsec_nanos(),
		}
	});
	assert_eq!(actual.birth, expected_birth);
	assert_eq!(EntryInfo::for_file(&file).unwrap(), actual);
}

#[test]
fn root_and_file_inspection_keep_open_descriptors_after_path_replacement() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	fs::write(fixture.0.join("selected/data"), b"original").unwrap();
	fs::write(outside.0.join("data"), b"different outside bytes").unwrap();
	let selected = Directory::open(&fixture.0.join("selected")).unwrap();
	let file = selected.open_regular_file(b"data").unwrap();
	let root_info = selected.inspect_self().unwrap();
	let file_info = EntryInfo::for_file(&file).unwrap();
	assert_eq!(root_info.kind, Kind::Directory);
	assert_eq!(file_info.length, 8);
	fs::rename(
		fixture.0.join("selected/data"),
		fixture.0.join("selected/moved"),
	)
	.unwrap();
	symlink(outside.0.join("data"), fixture.0.join("selected/data")).unwrap();
	fs::rename(fixture.0.join("selected"), fixture.0.join("moved")).unwrap();
	symlink(&outside.0, fixture.0.join("selected")).unwrap();
	assert_eq!(
		selected.inspect_self().unwrap().identity,
		root_info.identity
	);
	assert_eq!(EntryInfo::for_file(&file).unwrap(), file_info);
	assert_eq!(selected.inspect(b"data").unwrap().kind, Kind::Symlink);
	assert!(matches!(
		selected.inspect(b"."),
		Err(Error::InvalidBasename)
	));
}
