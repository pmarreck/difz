use super::*;
use crate::{Kind, windows::tests::Fixture};
use std::{
	fs,
	os::windows::fs::{OpenOptionsExt, symlink_file},
	path::Path,
};
use windows_sys::Win32::{
	Storage::FileSystem::{FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT},
	System::{
		Ioctl::FSCTL_SET_REPARSE_POINT,
		Threading::{GetCurrentProcess, GetProcessHandleCount},
	},
};

fn payload(tag: u32, substitute: &str, display: &str, relative: bool) -> Vec<u8> {
	let fixed = if tag == IO_REPARSE_TAG_SYMLINK { 12 } else { 8 };
	let target: Vec<u16> = substitute.encode_utf16().collect();
	let print: Vec<u16> = display.encode_utf16().collect();
	let print_offset = (target.len() + 1) * 2;
	let data_len = fixed + print_offset + (print.len() + 1) * 2;
	let mut bytes = vec![0; 8 + data_len];
	bytes[..4].copy_from_slice(&tag.to_le_bytes());
	bytes[4..6].copy_from_slice(&(data_len as u16).to_le_bytes());
	bytes[10..12].copy_from_slice(&((target.len() * 2) as u16).to_le_bytes());
	bytes[12..14].copy_from_slice(&(print_offset as u16).to_le_bytes());
	bytes[14..16].copy_from_slice(&((print.len() * 2) as u16).to_le_bytes());
	if fixed == 12 {
		bytes[16..20].copy_from_slice(&u32::from(relative).to_le_bytes());
	}
	for (offset, units) in [(0, &target), (print_offset, &print)] {
		for (index, unit) in units.iter().enumerate() {
			let start = 8 + fixed + offset + index * 2;
			bytes[start..start + 2].copy_from_slice(&unit.to_le_bytes());
		}
	}
	bytes
}
fn native_point(path: &Path, bytes: &[u8], directory: bool) {
	if directory {
		fs::create_dir(path).unwrap();
	} else {
		fs::write(path, b"").unwrap();
	}
	let file = fs::OpenOptions::new()
		.read(true)
		.write(true)
		.custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
		.open(path)
		.unwrap();
	let mut returned = 0;
	// Native fixture creation is required, never skipped. Its independently
	// chosen display text intentionally differs from the real substitute name.
	assert_ne!(
		unsafe {
			DeviceIoControl(
				file.as_raw_handle(),
				FSCTL_SET_REPARSE_POINT,
				bytes.as_ptr().cast(),
				bytes.len() as u32,
				ptr::null_mut(),
				0,
				&mut returned,
				ptr::null_mut(),
			)
		},
		0,
		"{}",
		io::Error::last_os_error()
	);
}

#[test]
fn native_link_targets_preserve_unicode_limits_parent_identity_and_handles() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::write(fixture.0.join("target"), b"real bytes").unwrap();
	symlink_file("target", fixture.0.join("link")).unwrap();
	fs::write(outside.0.join("caf\u{e9}\u{1f600}"), b"outside bytes").unwrap();
	let absolute = outside.0.join("caf\u{e9}\u{1f600}");
	symlink_file(&absolute, fixture.0.join("absolute")).unwrap();
	let root = Directory::open(&fixture.0).unwrap();
	assert_eq!(fs::read(fixture.0.join("link")).unwrap(), b"real bytes");
	assert_eq!(root.read_symlink(b"link", 6).unwrap(), b"target");
	for maximum in [0, 5] {
		assert!(matches!(
			root.read_symlink(b"link", maximum),
			Err(Error::LimitExceeded)
		));
	}
	let expected = absolute.to_str().unwrap().as_bytes();
	assert_eq!(
		root.read_symlink(b"absolute", expected.len()).unwrap(),
		expected
	);
	assert!(matches!(
		root.read_symlink(b"absolute", expected.len() - 1),
		Err(Error::LimitExceeded)
	));
	assert_eq!(
		fs::read(fixture.0.join("absolute")).unwrap(),
		b"outside bytes"
	);
	assert!(root.read_symlink(b"target", 128).is_err());
	assert!(root.read_symlink(b"missing", 128).is_err());
	fs::create_dir(fixture.0.join("selected")).unwrap();
	symlink_file("old-target", fixture.0.join("selected/link")).unwrap();
	let selected = root.open_directory(b"selected").unwrap();
	fs::rename(fixture.0.join("selected"), fixture.0.join("moved")).unwrap();
	fs::create_dir(fixture.0.join("selected")).unwrap();
	symlink_file("replacement", fixture.0.join("selected/link")).unwrap();
	assert_eq!(selected.read_symlink(b"link", 10).unwrap(), b"old-target");
	assert_eq!(
		fs::read_link(fixture.0.join("selected/link")).unwrap(),
		Path::new("replacement")
	);
	fn count() -> u32 {
		let mut count = 0;
		assert_ne!(
			unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut count) },
			0
		);
		count
	}
	let before = count();
	for _ in 0..64 {
		assert_eq!(root.read_symlink(b"link", 6).unwrap(), b"target");
		assert!(root.read_symlink(b"target", 6).is_err());
		assert!(root.read_symlink(b"link", 0).is_err());
	}
	assert_eq!(count(), before);
}

#[test]
fn native_reparse_substitutes_override_display_names_and_junctions_are_links() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::write(fixture.0.join("real"), b"actual target").unwrap();
	fs::write(fixture.0.join("cosmetic"), b"decoy").unwrap();
	native_point(
		&fixture.0.join("link"),
		&payload(IO_REPARSE_TAG_SYMLINK, "real", "cosmetic", true),
		false,
	);
	fs::write(outside.0.join("secret"), b"outside").unwrap();
	let absolute = outside.0.to_str().unwrap();
	native_point(
		&fixture.0.join("junction"),
		&payload(
			IO_REPARSE_TAG_MOUNT_POINT,
			&format!("\\??\\{absolute}"),
			"cosmetic-display",
			false,
		),
		true,
	);
	let root = Directory::open(&fixture.0).unwrap();
	assert_eq!(fs::read(fixture.0.join("link")).unwrap(), b"actual target");
	assert_eq!(root.read_symlink(b"link", 4).unwrap(), b"real");
	assert_eq!(root.inspect(b"link").unwrap().kind, Kind::Symlink);
	assert_eq!(root.inspect(b"junction").unwrap().kind, Kind::Symlink);
	assert_eq!(
		root.read_symlink(b"junction", absolute.len()).unwrap(),
		absolute.as_bytes()
	);
	assert!(root.open_directory(b"junction").is_err());
	assert_eq!(
		fs::read(fixture.0.join("junction/secret")).unwrap(),
		b"outside"
	);
}

#[test]
fn reparse_bounds_and_existing_nt_namespace_cases_are_enforced() {
	// Golden namespace behavior comes from the pinned Zig implementation's
	// ntToWin32Namespace and parseReadLinkPath contracts, not display names.
	for (target, relative, expected) in [
		("\\??\\C:\\test\\", false, "C:\\test\\"),
		("\\??\\UNC\\path1\\path2", false, "\\\\path1\\path2"),
		("\\??\\uNc/path1", false, "\\/path1"),
		("/??/C:\\test", false, "/??/C:\\test"),
		("\\Device\\disk\\file", false, "\\Device\\disk\\file"),
		("\\??\\C:\\test", true, "\\??\\C:\\test"),
		(
			"folder\\..\\caf\u{e9}\u{1f600}",
			true,
			"folder\\..\\caf\u{e9}\u{1f600}",
		),
	] {
		let record = payload(IO_REPARSE_TAG_SYMLINK, target, "ignored", relative);
		assert_eq!(
			decode(&record, expected.len()).unwrap(),
			expected.as_bytes()
		);
		assert!(matches!(
			decode(&record, expected.len() - 1),
			Err(Error::LimitExceeded)
		));
	}
	let valid = payload(IO_REPARSE_TAG_SYMLINK, "target", "display", true);
	for length in 0..valid.len() {
		assert!(decode(&valid[..length], 128).is_err());
	}
	for (at, value) in [
		(4, u16::MAX),
		(8, 1),
		(8, 65534),
		(10, 1),
		(10, 0),
		(12, 65534),
		(14, 65534),
	] {
		let mut broken = valid.clone();
		broken[at..at + 2].copy_from_slice(&value.to_le_bytes());
		assert!(decode(&broken, 128).is_err());
	}
	let mut broken = valid.clone();
	broken[..4].copy_from_slice(&0x12345678u32.to_le_bytes());
	assert!(matches!(decode(&broken, 128), Err(Error::WrongKind)));
	let mut broken = valid.clone();
	broken[16..20].copy_from_slice(&2u32.to_le_bytes());
	assert!(decode(&broken, 128).is_err());
	for unit in [0u16, 0xdc00, 0xd800] {
		let mut broken = valid.clone();
		broken[20..22].copy_from_slice(&unit.to_le_bytes());
		assert!(decode(&broken, 128).is_err());
	}
	assert!(
		decode(
			&payload(IO_REPARSE_TAG_MOUNT_POINT, "", "display", false),
			128
		)
		.is_err()
	);
}
