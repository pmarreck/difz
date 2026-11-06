use super::*;
use crate::metadata::tests::Reference;

fn compare(reference: &mut Reference, path: &[u8]) {
	assert_eq!(
		validate_path(path)
			.map(|_| Vec::new())
			.map_err(|e| format!("{e:?}")),
		reference.call(30, path),
		"path={path:?}"
	);
}
fn compare_link(reference: &mut Reference, path: &[u8], target: &[u8]) {
	let mut input = (path.len() as u32).to_le_bytes().to_vec();
	input.extend(path);
	input.extend(target);
	assert_eq!(
		validate_symlink_target(path, target)
			.map(|_| Vec::new())
			.map_err(|e| format!("{e:?}")),
		reference.call(31, &input),
		"path={path:?}, target={target:?}"
	);
}

#[test]
fn path_grammar_matches_native_binary_utf8_boundaries_and_error_precedence() {
	let mut reference = Reference::start();
	for path in [
		b"".as_slice(),
		b"file",
		b"dir/file",
		b".",
		b"..",
		b"/absolute",
		b"a//b",
		b"a/./b",
		b"a/../b",
		b"a/",
		b"C:file",
		b"z:/file",
		b"1:file",
		b"a:b/c",
		b"a\\b",
		b"nul\0tail",
		b"/\xff",
		b"/\0\\",
		b"C:\0\\",
		"é/文件/🌳".as_bytes(),
		b"\xc0\xaf",
		b"\xed\xa0\x80",
		b"\xf4\x90\x80\x80",
	] {
		compare(&mut reference, path);
	}
	for byte in 0..=255u8 {
		for path in [vec![byte], vec![b'a', byte, b'b'], vec![b'd', b'/', byte]] {
			compare(&mut reference, &path);
		}
	}
	for length in [4095, 4096, 4097] {
		let mut path = vec![b'x'; length];
		compare(&mut reference, &path);
		path[0] = 255; // Length rejection precedes UTF-8 validation.
		compare(&mut reference, &path);
	}
	assert!(validate_path(b"dir/file").is_ok());
	assert_eq!(validate_path(b"../file"), Err(Error::InvalidComponent));
}

#[test]
fn symlink_targets_match_native_lexical_containment_and_preserve_input() {
	let mut reference = Reference::start();
	for path in [
		b"link".as_slice(),
		b"dir/link",
		b"a/b/link",
		b"",
		b"bad/../link",
	] {
		for target in [
			b"".as_slice(),
			b"file",
			b".",
			b"..",
			b"../file",
			b"../../file",
			b"../../../file",
			b"x/../../file",
			b"x/../file",
			b"./file",
			b"x//file",
			b"x/",
			b"/absolute",
			b"C:file",
			b"x\\y",
			b"x\0y",
			"é/../文件".as_bytes(),
			b"\xff",
		] {
			let original = target.to_vec();
			compare_link(&mut reference, path, target);
			assert_eq!(target, original);
		}
	}
	for depth in 0..=8 {
		let path = format!("{}link", "dir/".repeat(depth));
		for parents in 0..=10 {
			let target = format!("{}file", "../".repeat(parents));
			compare_link(&mut reference, path.as_bytes(), target.as_bytes());
			assert_eq!(
				validate_symlink_target(path.as_bytes(), target.as_bytes()).is_ok(),
				parents <= depth
			);
		}
	}
	for byte in 0..=255u8 {
		compare_link(&mut reference, b"dir/link", &[b'x', byte, b'y']);
	}
	// Target length has no tree-grammar cap; link paths retain the 4096-byte cap.
	compare_link(&mut reference, b"link", &vec![b'x'; 4097]);
	compare_link(&mut reference, &vec![b'x'; 4097], b"file");
}
