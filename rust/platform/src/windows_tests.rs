use super::*;
use std::{
	fs,
	os::windows::fs::{symlink_dir, symlink_file},
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
};
use windows_sys::Win32::{
	Foundation::{GetHandleInformation, HANDLE_FLAG_INHERIT},
	Storage::FileSystem::ReadFile,
	System::Threading::{GetCurrentProcess, GetProcessHandleCount},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
	fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"difz-windows-capability-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
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
fn native_read(file: &File) -> Vec<u8> {
	let mut bytes = [0u8; 64];
	let mut count = 0;
	// Independent OS readback of the actual returned handle, outside the
	// capability reader. The test owns the writable buffer and count slot.
	assert_ne!(
		unsafe {
			ReadFile(
				file.as_raw_handle(),
				bytes.as_mut_ptr(),
				bytes.len() as u32,
				&mut count,
				ptr::null_mut(),
			)
		},
		0
	);
	bytes[..count as usize].to_vec()
}
#[test]
fn real_windows_handles_classify_children_and_preserve_binary_bytes() {
	let fixture = Fixture::new();
	fs::create_dir(fixture.0.join("sub")).unwrap();
	fs::write(fixture.0.join("sub/data"), b"\0\xff\r\nbytes\x1a").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	let sub = root.open_directory(b"sub").unwrap();
	let file = sub.open_regular_file(b"data").unwrap();
	for handle in [&root.file, &sub.file, &file] {
		let mut flags = 0;
		// The kernel reports actual inheritance state for each live handle.
		assert_ne!(
			unsafe { GetHandleInformation(handle.as_raw_handle(), &mut flags) },
			0
		);
		assert_eq!(flags & HANDLE_FLAG_INHERIT, 0);
	}
	assert_eq!(native_read(&file), b"\0\xff\r\nbytes\x1a");
	assert!(matches!(
		root.open_regular_file(b"sub"),
		Err(Error::WrongKind)
	));
	assert!(matches!(sub.open_directory(b"data"), Err(Error::WrongKind)));
	assert!(Directory::open(&fixture.0.join("sub/data")).is_err());
	assert!(root.open_regular_file(b"missing").is_err());
}
#[test]
fn parent_path_replacement_cannot_redirect_an_opened_directory() {
	let fixture = Fixture::new();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	fs::write(fixture.0.join("selected/data"), b"original").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	let selected = root.open_directory(b"selected").unwrap();
	fs::rename(fixture.0.join("selected"), fixture.0.join("moved")).unwrap();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	fs::write(fixture.0.join("selected/data"), b"replacement").unwrap();
	assert_eq!(
		native_read(&selected.open_regular_file(b"data").unwrap()),
		b"original"
	);
	assert_eq!(
		fs::read(fixture.0.join("selected/data")).unwrap(),
		b"replacement"
	);
}
#[test]
fn windows_reparse_points_are_rejected_at_root_and_child_boundaries() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::write(outside.0.join("secret"), b"outside").unwrap();
	// Fixture creation must succeed. A missing privilege is not a passing
	// no-follow test and must not silently skip this required control.
	symlink_file(outside.0.join("secret"), fixture.0.join("link")).unwrap();
	symlink_dir(&outside.0, fixture.0.join("linked-dir")).unwrap();
	assert_ne!(
		fs::symlink_metadata(fixture.0.join("link"))
			.unwrap()
			.file_attributes()
			& FILE_ATTRIBUTE_REPARSE_POINT,
		0
	);
	assert_ne!(
		fs::symlink_metadata(fixture.0.join("linked-dir"))
			.unwrap()
			.file_attributes()
			& FILE_ATTRIBUTE_REPARSE_POINT,
		0
	);
	let root = Directory::open(&fixture.0).unwrap();
	assert!(matches!(
		root.open_regular_file(b"link"),
		Err(Error::WrongKind)
	));
	assert!(matches!(
		root.open_directory(b"linked-dir"),
		Err(Error::WrongKind)
	));
	assert!(matches!(
		Directory::open(&fixture.0.join("linked-dir")),
		Err(Error::WrongKind)
	));
	assert_eq!(fs::read(outside.0.join("secret")).unwrap(), b"outside");
}
#[test]
fn bounded_reads_and_component_grammar_fail_before_ambiguous_access() {
	let fixture = Fixture::new();
	fs::write(fixture.0.join("data"), b"\0\xffbytes").unwrap();
	fs::write(fixture.0.join("empty"), b"").unwrap();
	fs::write(fixture.0.join("caf\u{e9}\u{1f600}"), b"Unicode name").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	assert_eq!(root.read_file(b"data", 7).unwrap(), b"\0\xffbytes");
	assert_eq!(root.read_file(b"data", 8).unwrap(), b"\0\xffbytes");
	assert!(matches!(
		root.read_file(b"data", 6),
		Err(Error::LimitExceeded)
	));
	assert!(matches!(
		root.read_file(b"data", 0),
		Err(Error::LimitExceeded)
	));
	assert!(root.read_file(b"empty", 0).unwrap().is_empty());
	assert_eq!(
		root.read_file("caf\u{e9}\u{1f600}".as_bytes(), 12).unwrap(),
		b"Unicode name"
	);
	for name in [
		b"".as_slice(),
		b".",
		b"..",
		b"a/b",
		b"a\\b",
		b"a\0b",
		b"\xff",
		b"C:data",
		b"data:stream",
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
#[test]
fn owned_child_handles_close_after_success_and_kind_failures() {
	fn count() -> u32 {
		let mut count = 0;
		// This observes only our current Windows process and a live output slot.
		assert_ne!(
			unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut count) },
			0
		);
		count
	}
	let fixture = Fixture::new();
	fs::create_dir(fixture.0.join("sub")).unwrap();
	fs::write(fixture.0.join("data"), b"data").unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	let before = count();
	for _ in 0..128 {
		drop(root.open_directory(b"sub").unwrap());
		drop(root.open_regular_file(b"data").unwrap());
		assert!(root.open_regular_file(b"sub").is_err());
		assert!(root.open_directory(b"data").is_err());
	}
	assert_eq!(count(), before);
}
