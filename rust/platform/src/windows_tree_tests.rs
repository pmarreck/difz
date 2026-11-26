use super::tests::{Fixture, expected_cli_error};
use std::{
	ffi::OsStr,
	fs,
	os::windows::fs::symlink_file,
	path::Path,
	process::{Command, Output},
};

fn encode(program: &OsStr, source: &Path, target: &Path, extra: &[&str]) -> Output {
	// Stdout exercises the public encoder without depending on the separately
	// unfinished Windows atomic-file publication operation.
	Command::new(program)
		.args([
			"--no-progress",
			"--omit-metadata",
			"xattr,acl,timestamps,finder,sparse,hardlink",
		])
		.args(extra)
		.arg(source)
		.arg(target)
		.output()
		.unwrap()
}

#[test]
fn public_rust_directory_encoding_matches_original_bytes_and_explicit_metadata_scope() {
	let fixture = Fixture::new();
	let original = std::env::var_os("DIFZ_WINDOWS_ORACLE").expect("required original executable");
	let rust = std::env::var_os("DIFZ_WINDOWS_RUST").expect("required packaged Rust executable");
	let source = fixture.0.join("source");
	let target = fixture.0.join("target");
	let old: Vec<u8> = (0..65536usize).map(|index| (index % 251) as u8).collect();
	let mut new = old.clone();
	new[1024..1100].fill(0xfe);
	new.extend_from_slice(b"new\0\xff bytes");
	for (root, bytes) in [(&source, old.as_slice()), (&target, new.as_slice())] {
		fs::create_dir(root).unwrap();
		fs::create_dir(root.join("empty")).unwrap();
		fs::create_dir(root.join("nested")).unwrap();
		fs::write(root.join("nested/caf\u{e9}\u{1f600}"), bytes).unwrap();
		fs::write(root.join("ignored.tmp"), b"retained only without selection").unwrap();
		symlink_file("nested\\caf\u{e9}\u{1f600}", root.join("link")).unwrap();
		assert_eq!(fs::read(root.join("link")).unwrap(), bytes);
	}
	for rules in [&[][..], &["--allow", "nested/**"][..]] {
		let reference = encode(&original, &source, &target, rules);
		assert!(
			reference.status.success(),
			"original: {}",
			String::from_utf8_lossy(&reference.stderr)
		);
		assert!(reference.stdout.starts_with(b"DIFZTREE"));
		let candidate = encode(&rust, &source, &target, rules);
		assert!(
			candidate.status.success(),
			"Rust public directory encode: {}",
			String::from_utf8_lossy(&candidate.stderr)
		);
		assert_eq!(candidate.stdout, reference.stdout);
	}
	let unsupported = Command::new(&rust)
		.args([
			"--no-progress",
			"--omit-metadata",
			"xattr,acl,finder,sparse,hardlink",
		])
		.arg(&source)
		.arg(&target)
		.output()
		.unwrap();
	assert_eq!(unsupported.status.code(), Some(1));
	assert!(unsupported.stdout.is_empty());
	assert_eq!(
		String::from_utf8_lossy(&unsupported.stderr)
			.replace("\r\n", "\n")
			.trim(),
		expected_cli_error("operation is unsupported on this target")
	);
	assert_eq!(
		fs::read(source.join("nested/caf\u{e9}\u{1f600}")).unwrap(),
		old
	);
	assert_eq!(
		fs::read(target.join("nested/caf\u{e9}\u{1f600}")).unwrap(),
		new
	);
}

#[test]
fn bounded_tree_capture_keeps_renamed_roots_and_requires_every_family_omitted() {
	use crate::{
		Directory, Error,
		tree_capture::{Limits, Options, capture},
	};
	use difz_core::metadata::{Family, Omit};
	let fixture = Fixture::new();
	let selected = fixture.0.join("selected");
	let moved = fixture.0.join("moved");
	fs::create_dir(&selected).unwrap();
	fs::create_dir(selected.join("child")).unwrap();
	fs::write(selected.join("child/data"), b"original\0\xff").unwrap();
	let root = Directory::open(&selected).unwrap();
	let all = Family::ALL
		.iter()
		.fold(0, |bits, family| bits | family.bit());
	let options = Options {
		omit: Omit::from_bits(all).unwrap(),
		..Options::default()
	};
	let before = capture(&root, options).unwrap();
	fs::rename(&selected, &moved).unwrap();
	fs::create_dir(&selected).unwrap();
	fs::write(selected.join("replacement"), b"different tree").unwrap();
	let after = capture(&root, options).unwrap();
	assert_eq!(before.snapshot(), after.snapshot());
	assert!(after.contains_directory(&root).unwrap());
	assert!(
		after
			.contains_directory(&root.open_directory(b"child").unwrap())
			.unwrap()
	);
	assert!(
		!after
			.contains_directory(&Directory::open(&selected).unwrap())
			.unwrap()
	);
	for limits in [
		Limits {
			entries: 0,
			..Limits::default()
		},
		Limits {
			bytes: 0,
			..Limits::default()
		},
		Limits {
			metadata: crate::metadata_limits::Limits {
				metadata_bytes: 0,
				..crate::metadata_limits::Limits::default()
			},
			..Limits::default()
		},
	] {
		assert!(matches!(
			capture(&root, Options { limits, ..options }),
			Err(Error::LimitExceeded)
		));
	}
	for family in Family::ALL {
		let omit = Omit::from_bits(all & !family.bit()).unwrap();
		assert!(matches!(
			capture(&root, Options { omit, ..options }),
			Err(Error::UnsupportedMetadata)
		));
	}
	assert_eq!(
		fs::read(moved.join("child/data")).unwrap(),
		b"original\0\xff"
	);
	assert_eq!(
		fs::read(selected.join("replacement")).unwrap(),
		b"different tree"
	);
}
