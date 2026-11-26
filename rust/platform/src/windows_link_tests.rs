use super::*;
use crate::{
	Kind,
	windows::tests::{Fixture, expected_cli_error},
};
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

#[test]
fn original_directory_round_trips_use_portable_link_targets_and_reject_escapes() {
	use difz_core::{
		directory::{CanonicalSnapshot, Content, Entry, Mode, Snapshot},
		metadata::CanonicalMetadata,
		tree_patch::{EnvelopeLimits, Header},
	};
	use std::{borrow::Cow, process::Command};
	let fixture = Fixture::new();
	let oracle =
		std::env::var_os("DIFZ_WINDOWS_ORACLE").expect("required original Windows executable");
	let source = fixture.0.join("source");
	let target = fixture.0.join("target");
	let output = fixture.0.join("output");
	let patch = fixture.0.join("tree.patch");
	let make_tree = |root: &Path, bytes: &[u8]| {
		fs::create_dir(root).unwrap();
		fs::create_dir(root.join("dir")).unwrap();
		fs::write(root.join("dir/payload"), bytes).unwrap();
	};
	let add_links = |root: &Path, bytes: &[u8]| {
		for (name, target) in [("link", "dir\\payload"), ("dir/link", "..\\dir\\payload")] {
			native_point(
				&root.join(name),
				&payload(IO_REPARSE_TAG_SYMLINK, target, "cosmetic", true),
				false,
			);
		}
		assert_eq!(fs::read(root.join("link")).unwrap(), bytes);
		assert_eq!(fs::read(root.join("dir/link")).unwrap(), bytes);
	};
	let source_bytes = b"source\0\xff bytes";
	let target_bytes = b"changed\0\xfe bytes";
	make_tree(&source, source_bytes);
	make_tree(&target, target_bytes);
	let expected = |bytes: &[u8]| {
		CanonicalSnapshot::new(Snapshot {
			root: CanonicalMetadata::default(),
			entries: [
				(
					b"dir".as_slice(),
					Content::Directory {
						mode: Mode::from_bits(0o755).unwrap(),
					},
				),
				(
					b"dir/link",
					Content::Symlink {
						target: Cow::Borrowed(b"../dir/payload"),
					},
				),
				(
					b"dir/payload",
					Content::File {
						mode: Mode::from_bits(0o644).unwrap(),
						bytes: Cow::Borrowed(bytes),
					},
				),
				(
					b"link",
					Content::Symlink {
						target: Cow::Borrowed(b"dir/payload"),
					},
				),
			]
			.into_iter()
			.map(|(path, content)| Entry {
				path: Cow::Borrowed(path),
				content,
				metadata: CanonicalMetadata::default(),
			})
			.collect(),
		})
		.unwrap()
		.hash()
	};
	let encode = |from: &Path, to: &Path, patch: &Path| {
		Command::new(&oracle)
			.args([
				"--no-progress",
				"--omit-metadata",
				"xattr,acl,timestamps,finder,sparse,hardlink",
			])
			.arg(from)
			.arg(to)
			.arg("-o")
			.arg(patch)
			.output()
			.unwrap()
	};
	let result = encode(&source, &target, &fixture.0.join("plain.patch"));
	assert!(
		result.status.success(),
		"original directory control without links: {}",
		String::from_utf8_lossy(&result.stderr)
	);
	add_links(&source, source_bytes);
	add_links(&target, target_bytes);
	let result = encode(&source, &target, &patch);
	assert!(
		result.status.success(),
		"original encode: {}",
		String::from_utf8_lossy(&result.stderr)
	);
	let bytes = fs::read(&patch).unwrap();
	let header = Header::decode_prefix(&bytes, EnvelopeLimits::default())
		.unwrap()
		.0;
	assert_eq!(header.source_hash, expected(source_bytes));
	assert_eq!(header.target_hash, expected(target_bytes));
	let result = Command::new(&oracle)
		.args(["--no-progress", "--patch"])
		.arg(&source)
		.arg(&patch)
		.arg("-o")
		.arg(&output)
		.output()
		.unwrap();
	assert!(
		result.status.success(),
		"original apply: {}",
		String::from_utf8_lossy(&result.stderr)
	);
	for name in ["dir/payload", "dir/link", "link"] {
		assert_eq!(fs::read(output.join(name)).unwrap(), target_bytes);
		assert_eq!(fs::read(source.join(name)).unwrap(), source_bytes);
	}
	for name in ["dir/link", "link"] {
		assert!(
			fs::symlink_metadata(output.join(name))
				.unwrap()
				.file_type()
				.is_symlink()
		);
	}
	let recaptured = fixture.0.join("recaptured.patch");
	let result = encode(&output, &output, &recaptured);
	assert!(
		result.status.success(),
		"original recapture: {}",
		String::from_utf8_lossy(&result.stderr)
	);
	let bytes = fs::read(recaptured).unwrap();
	let header = Header::decode_prefix(&bytes, EnvelopeLimits::default())
		.unwrap()
		.0;
	assert_eq!(header.source_hash, expected(target_bytes));
	assert_eq!(header.target_hash, expected(target_bytes));
	let escaping = fixture.0.join("escaping");
	fs::create_dir(&escaping).unwrap();
	fs::write(fixture.0.join("outside"), b"outside remains unchanged").unwrap();
	symlink_file("../outside", escaping.join("escape")).unwrap();
	// Wine exposes this exact relative target but following it fails with
	// ERROR_INVALID_NAME. Anchor lexical containment in native target readback;
	// the absolute fixture below proves a reachable outside file is rejected.
	assert_eq!(
		Directory::open(&escaping)
			.unwrap()
			.read_symlink(b"escape", 64)
			.unwrap(),
		b"../outside"
	);
	let absolute = fixture.0.join("absolute-escaping");
	fs::create_dir(&absolute).unwrap();
	symlink_file(fixture.0.join("outside"), absolute.join("escape")).unwrap();
	assert_eq!(
		fs::read(absolute.join("escape")).unwrap(),
		b"outside remains unchanged"
	);
	let rejected = fixture.0.join("rejected.patch");
	let result = encode(&source, &escaping, &rejected);
	assert!(!result.status.success(), "escaping target must fail");
	assert!(!rejected.exists());
	let rejected_absolute = fixture.0.join("rejected-absolute.patch");
	let result = encode(&source, &absolute, &rejected_absolute);
	assert!(
		!result.status.success(),
		"absolute outside target must fail"
	);
	assert!(!rejected_absolute.exists());
	assert_eq!(
		fs::read(fixture.0.join("outside")).unwrap(),
		b"outside remains unchanged"
	);
	assert_eq!(fs::read(source.join("dir/payload")).unwrap(), source_bytes);
	// A valid portable patch can request modes Windows cannot represent.
	// Rejection must return through the ABI and remove its owned stage.
	let empty = fixture.0.join("empty");
	fs::create_dir(&empty).unwrap();
	let restricted = CanonicalSnapshot::new(Snapshot {
		root: CanonicalMetadata::default(),
		entries: vec![Entry {
			path: Cow::Borrowed(b"restricted"),
			content: Content::Directory {
				mode: Mode::from_bits(0o700).unwrap(),
			},
			metadata: CanonicalMetadata::default(),
		}],
	})
	.unwrap();
	let mode_patch = difz_core::tree_patch::create(
		&CanonicalSnapshot::default(),
		&restricted,
		difz_core::tree_patch::CreateOptions {
			rules: &[],
			omit: difz_core::metadata::Omit::from_bits(0x3f).unwrap(),
		},
	)
	.unwrap();
	let mode_patch_path = fixture.0.join("mode.patch");
	fs::write(&mode_patch_path, mode_patch).unwrap();
	let unsupported = fixture.0.join("unsupported");
	let result = Command::new(&oracle)
		.args(["--no-progress", "--patch"])
		.arg(&empty)
		.arg(mode_patch_path)
		.arg("-o")
		.arg(&unsupported)
		.output()
		.unwrap();
	assert!(
		!result.status.success(),
		"unsupported Windows mode must fail"
	);
	assert_eq!(result.status.code(), Some(1));
	assert!(result.stdout.is_empty());
	assert_eq!(
		String::from_utf8_lossy(&result.stderr)
			.replace("\r\n", "\n")
			.trim(),
		expected_cli_error("directory patch failed")
	);
	assert!(!unsupported.exists());
	assert_eq!(fs::read_dir(&empty).unwrap().count(), 0);
	for child in fs::read_dir(&fixture.0).unwrap() {
		assert!(
			!child
				.unwrap()
				.file_name()
				.to_str()
				.unwrap()
				.contains(".difz-stage-")
		);
	}
}
