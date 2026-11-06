use super::*;
use std::{
	fs,
	io::Read,
	os::unix::fs::symlink,
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
};
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
	fn new() -> Self {
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
