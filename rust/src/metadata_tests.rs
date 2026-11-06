use super::*;
#[path = "metadata_canonical_tests.rs"]
mod canonical;
use std::{
	io::{BufReader, Read, Write},
	process::{Child, ChildStdin, ChildStdout, Command, Stdio},
};

fn native_once(mode: u32, input: &[u8]) -> Result<Vec<u8>, String> {
	let mut process = Command::new(std::env::var_os("DIFZ_METADATA_ORACLE").unwrap())
		.arg(mode.to_string())
		.stdin(Stdio::piped())
		.stdout(Stdio::piped())
		.stderr(Stdio::piped())
		.spawn()
		.unwrap();
	process.stdin.take().unwrap().write_all(input).unwrap();
	let result = process.wait_with_output().unwrap();
	match result.status.code() {
		Some(0) => {
			assert!(result.stderr.is_empty());
			Ok(result.stdout)
		}
		Some(1) => {
			assert!(result.stdout.is_empty());
			Err(String::from_utf8(result.stderr).unwrap())
		}
		_ => panic!(
			"oracle crashed or setup failed: {:?} {:?}",
			result.status, result.stderr
		),
	}
}

struct Reference {
	child: Child,
	input: Option<ChildStdin>,
	output: BufReader<ChildStdout>,
}
impl Reference {
	fn start() -> Self {
		let mut child = Command::new(std::env::var_os("DIFZ_METADATA_ORACLE").unwrap())
			.arg("--stream")
			.stdin(Stdio::piped())
			.stdout(Stdio::piped())
			.stderr(Stdio::inherit())
			.spawn()
			.unwrap();
		let input = child.stdin.take();
		let output = BufReader::new(child.stdout.take().unwrap());
		Self {
			child,
			input,
			output,
		}
	}
	fn call(&mut self, mode: u32, bytes: &[u8]) -> Result<Vec<u8>, String> {
		assert!(bytes.len() <= 1 << 20);
		let input = self.input.as_mut().unwrap();
		input.write_all(&mode.to_le_bytes()).unwrap();
		input
			.write_all(&(bytes.len() as u32).to_le_bytes())
			.unwrap();
		input.write_all(bytes).unwrap();
		input.flush().unwrap();
		let mut header = [0; 5];
		self.output.read_exact(&mut header).unwrap();
		let length = u32::from_le_bytes(header[1..].try_into().unwrap()) as usize;
		assert!(length <= 1 << 20, "oversize oracle response");
		let mut response = vec![0; length];
		self.output.read_exact(&mut response).unwrap();
		match header[0] {
			0 => Ok(response),
			1 => Err(String::from_utf8(response).unwrap()),
			status => panic!("invalid oracle status {status}"),
		}
	}
}
impl Drop for Reference {
	fn drop(&mut self) {
		drop(self.input.take());
		if std::thread::panicking() {
			// Reap only our child; a failed read must not leave it blocked writing.
			let _ = self.child.kill();
			let _ = self.child.wait();
		} else {
			assert!(
				self.child.wait().unwrap().success(),
				"reference process failed"
			);
		}
	}
}

fn compare<T>(
	reference: &mut Reference,
	actual: Result<T, Error>,
	mode: u32,
	bytes: &[u8],
	encode: impl Fn(T) -> Vec<u8>,
) {
	let actual = actual.map(encode).map_err(|e| format!("{e:?}"));
	assert_eq!(
		actual,
		reference.call(mode, bytes),
		"mode={mode} bytes={bytes:?}"
	);
}

#[test]
fn omission_masks_and_family_names_match_the_reference_over_the_finite_domain() {
	let mut reference = Reference::start();
	let names = ["xattr", "acl", "timestamps", "finder", "sparse", "hardlink"];
	for mask in (0..=255u32)
		.chain((6..32).map(|bit| 1 << bit))
		.chain([u32::MAX])
	{
		compare(
			&mut reference,
			Omit::from_bits(mask),
			0,
			&mask.to_le_bytes(),
			|omit| omit.bits().to_le_bytes().to_vec(),
		);
		if mask < 64 {
			let omit = Omit::from_bits(mask).unwrap();
			let mut selected = Vec::new();
			for (i, name) in names.iter().enumerate() {
				assert_eq!(Family::ALL[i].name(), *name);
				assert_eq!(omit.contains(Family::ALL[i]), mask & (1 << i) != 0);
				if mask & (1 << i) != 0 {
					selected.push(*name);
				}
			}
			let text = selected.join(",");
			assert_eq!(Omit::parse(text.as_bytes()), Ok(omit));
			compare(
				&mut reference,
				Omit::parse(text.as_bytes()),
				1,
				text.as_bytes(),
				|omit| omit.bits().to_le_bytes().to_vec(),
			);
		}
	}
	for text in [
		" ",
		",",
		"xattr,",
		"acl,acl",
		"unknown",
		"XATTR",
		"\tacl",
		"acl\t",
		" xattr , acl ",
		"none",
		"all",
	] {
		compare(
			&mut reference,
			Omit::parse(text.as_bytes()),
			1,
			text.as_bytes(),
			|omit| omit.bits().to_le_bytes().to_vec(),
		);
	}
	compare(&mut reference, Omit::parse(&[0xff]), 1, &[0xff], |omit| {
		omit.bits().to_le_bytes().to_vec()
	});
}

fn time_bytes(value: Option<Time>) -> Vec<u8> {
	match value {
		None => vec![0],
		Some(Time { sec, nsec }) => {
			let mut out = vec![1];
			out.extend(sec.to_le_bytes());
			out.extend(nsec.to_le_bytes());
			out
		}
	}
}

#[test]
fn timestamp_presence_signed_seconds_nanoseconds_and_flag_bytes_match_reference() {
	let mut reference = Reference::start();
	let mut values = vec![None];
	for sec in [i64::MIN, -1, 0, 1, i64::MAX] {
		for nsec in [0, 1, 999_999_999, 1_000_000_000, u32::MAX] {
			values.push(Some(Time { sec, nsec }));
		}
	}
	for value in values {
		let bytes = time_bytes(value);
		compare(
			&mut reference,
			decode_time_override(&bytes),
			2,
			&bytes,
			time_bytes,
		);
		let expected = if value.is_some_and(|t| t.nsec >= 1_000_000_000) {
			Err(Error::InvalidNsec)
		} else {
			Ok(bytes)
		};
		assert_eq!(
			encode_time_override(value).map(|b| b.as_bytes().to_vec()),
			expected
		);
	}
	for flag in 0..=255u8 {
		let mut bytes = vec![flag];
		bytes.resize(13, 0);
		compare(
			&mut reference,
			decode_time_override(&bytes),
			2,
			&bytes,
			time_bytes,
		);
		compare(
			&mut reference,
			decode_time_override(&[flag]),
			2,
			&[flag],
			time_bytes,
		);
	}
}

#[test]
fn modification_override_binds_original_and_observed_values_with_exact_lengths() {
	let mut reference = Reference::start();
	for original in [
		None,
		Some(Time {
			sec: -42,
			nsec: 999_999_999,
		}),
	] {
		for observed in [
			Time { sec: 0, nsec: 0 },
			Time {
				sec: i64::MAX,
				nsec: 999_999_999,
			},
			Time {
				sec: 1,
				nsec: 1_000_000_000,
			},
		] {
			let value = ModificationOverride { original, observed };
			let mut bytes = time_bytes(original);
			bytes.extend(observed.sec.to_le_bytes());
			bytes.extend(observed.nsec.to_le_bytes());
			let expected = if observed.nsec >= 1_000_000_000 {
				Err(Error::InvalidNsec)
			} else {
				Ok(bytes.clone())
			};
			assert_eq!(
				encode_modification_override(value).map(|b| b.as_bytes().to_vec()),
				expected
			);
			compare(
				&mut reference,
				decode_modification_override(&bytes),
				3,
				&bytes,
				|v| encode_modification_override(v).unwrap().as_bytes().to_vec(),
			);
			for length in 0..bytes.len() {
				compare(
					&mut reference,
					decode_modification_override(&bytes[..length]),
					3,
					&bytes[..length],
					|v| encode_modification_override(v).unwrap().as_bytes().to_vec(),
				);
			}
			bytes.push(0);
			compare(
				&mut reference,
				decode_modification_override(&bytes),
				3,
				&bytes,
				|v| encode_modification_override(v).unwrap().as_bytes().to_vec(),
			);
		}
	}
}

#[test]
fn attribute_names_match_reference_for_binary_bytes_reserved_names_and_size_limits() {
	let mut reference = Reference::start();
	for byte in 0..=255u8 {
		let name = [b'a', byte, b'b'];
		for (class, mode) in [(XattrClass::Logical, 4), (XattrClass::Raw, 5)] {
			compare(
				&mut reference,
				validate_xattr_name(class, &name),
				mode,
				&name,
				|()| vec![],
			);
		}
	}
	for length in [0, 1, 126, 127, 128, 254, 255, 256] {
		let name = vec![b'a'; length];
		for (class, mode) in [(XattrClass::Logical, 4), (XattrClass::Raw, 5)] {
			compare(
				&mut reference,
				validate_xattr_name(class, &name),
				mode,
				&name,
				|()| vec![],
			);
		}
	}
	for name in [
		"name",
		" name",
		"name ",
		"name.",
		"User.attr",
		"COM.APPLE.attr",
		"$name",
		"ZONE.IDENTIFIER",
		"a:b",
		"属性",
		"e\u{301}",
	] {
		for (class, mode) in [(XattrClass::Logical, 4), (XattrClass::Raw, 5)] {
			compare(
				&mut reference,
				validate_xattr_name(class, name.as_bytes()),
				mode,
				name.as_bytes(),
				|()| vec![],
			);
		}
	}
	assert_eq!(TRANSPORT_NAMES.len(), 10);
	for reserved in [
		"difz.btime",
		"difz.mtime",
		"difz.finder-info",
		"difz.bsd-flags",
		"difz.native-acl",
		"difz.portable-acl",
		"difz.sparse-holes",
		"difz.hardlink-to",
		"difz.raw-xattrs",
		"difz.symlinks",
	] {
		assert!(TRANSPORT_NAMES.contains(&reserved.as_bytes()));
		for name in [
			reserved.to_owned(),
			format!("user.{reserved}"),
			reserved.to_uppercase(),
			format!("USER.{reserved}"),
			format!("{reserved}x"),
		] {
			assert_eq!(
				vec![u8::from(is_transport_name(name.as_bytes()))],
				reference.call(8, name.as_bytes()).unwrap()
			);
			for (class, mode) in [(XattrClass::Logical, 4), (XattrClass::Raw, 5)] {
				compare(
					&mut reference,
					validate_xattr_name(class, name.as_bytes()),
					mode,
					name.as_bytes(),
					|()| vec![],
				);
			}
		}
	}
}

#[test]
fn hardlink_and_acl_identity_validation_matches_reference() {
	let mut reference = Reference::start();
	for path in [
		"",
		"a",
		"a/b",
		"/a",
		"a/",
		"a//b",
		".",
		"..",
		"a/./b",
		"a/../b",
		"a\\b",
		"C:a",
		"z:/a",
		"0:a",
		"a:b",
		"路径/文件",
		"a\0b",
	] {
		compare(
			&mut reference,
			validate_hardlink(path.as_bytes()),
			6,
			path.as_bytes(),
			|()| vec![],
		);
	}
	for length in [4095, 4096, 4097] {
		let path = vec![b'a'; length];
		compare(
			&mut reference,
			validate_hardlink(&path),
			6,
			&path,
			|()| vec![],
		);
	}
	for byte in 0..=255u8 {
		let name = [b'a', byte, b'b'];
		compare(
			&mut reference,
			validate_hardlink(&name),
			6,
			&name,
			|()| vec![],
		);
	}
	for tag in 0..=255u8 {
		for name in [b"".as_slice(), b"name", b"a/b", b"a\0b", b"\xff", b"a\\b"] {
			let mut input = vec![tag];
			input.extend(name);
			compare(
				&mut reference,
				AceTag::try_from(tag).and_then(|tag| validate_ace_name(tag, name)),
				7,
				&input,
				|()| vec![],
			);
		}
	}
}

#[test]
fn raw_attribute_platform_eligibility_keeps_its_separate_structural_contract() {
	let mut reference = Reference::start();
	assert_eq!(Os::ALL.len(), 3);
	for tag in 0..=255u8 {
		let actual = Os::try_from(tag).map(|os| vec![u8::from(raw_accepted(os, b"user.name"))]);
		let mut input = vec![tag];
		input.extend(b"user.name");
		compare(&mut reference, actual, 9, &input, |value| value);
	}
	for os in Os::ALL.iter().copied() {
		for name in [
			b"".as_slice(),
			b"user.name",
			b"system.name",
			b"security.name",
			b"trusted.name",
			b"user.",
			b"User.name",
			b"other.name",
			b"a/b",
			b"a\\b",
			b"a:b",
			b"a\0b",
			b"\xff",
		] {
			let mut input = vec![os as u8];
			input.extend(name);
			assert_eq!(
				vec![u8::from(raw_accepted(os, name))],
				reference.call(9, &input).unwrap()
			);
		}
		for length in [127, 128, 255, 256] {
			let mut input = vec![os as u8];
			input.extend(vec![b'a'; length]);
			assert_eq!(
				vec![u8::from(raw_accepted(os, &input[1..]))],
				reference.call(9, &input).unwrap()
			);
		}
	}
}

#[test]
fn streaming_reference_matches_one_shot_and_rejects_truncated_or_oversize_requests() {
	let mut reference = Reference::start();
	let cases = [
		(0, 0u32.to_le_bytes().to_vec()),
		(0, u32::MAX.to_le_bytes().to_vec()),
		(1, b"acl".to_vec()),
		(1, b"acl,acl".to_vec()),
		(2, vec![0]),
		(2, vec![2]),
		(3, vec![0; 13]),
		(3, vec![0; 12]),
		(4, b"hello".to_vec()),
		(4, vec![0]),
		(5, vec![0xff]),
		(5, vec![b'/']),
		(6, b"a/b".to_vec()),
		(6, b"../a".to_vec()),
		(7, vec![4, b'n', b'a', b'm', b'e']),
		(7, vec![0]),
		(8, b"difz.btime".to_vec()),
		(8, b"USER.difz.btime".to_vec()),
		(9, vec![1, b'u', b's', b'e', b'r', b'.', b'n']),
		(9, vec![0]),
		(99, vec![0, 0xff]),
	];
	for (mode, input) in cases {
		assert_eq!(reference.call(mode, &input), native_once(mode, &input));
	}
	drop(reference); // A clean EOF must terminate successfully after valid and invalid records.
	let mut oversize = 0u32.to_le_bytes().to_vec();
	oversize.extend(((1u32 << 20) + 1).to_le_bytes());
	let mut short_body = 0u32.to_le_bytes().to_vec();
	short_body.extend(4u32.to_le_bytes());
	short_body.extend([0; 3]);
	for input in [vec![0], vec![0; 7], oversize, short_body] {
		let mut child = Command::new(std::env::var_os("DIFZ_METADATA_ORACLE").unwrap())
			.arg("--stream")
			.stdin(Stdio::piped())
			.stdout(Stdio::piped())
			.stderr(Stdio::piped())
			.spawn()
			.unwrap();
		child.stdin.take().unwrap().write_all(&input).unwrap();
		let result = child.wait_with_output().unwrap();
		assert_eq!(result.status.code(), Some(2));
		assert!(result.stdout.is_empty());
	}
}

#[test]
fn portable_permissions_match_native_wire_decoding_over_every_byte() {
	let mut reference = Reference::start();
	for bits in 0..=255u8 {
		compare(
			&mut reference,
			Permissions::from_bits(bits),
			10,
			&[bits],
			|p| vec![p.bits()],
		);
		if bits < 8 {
			let p = Permissions::from_bits(bits).unwrap();
			for (permission, bit) in [
				(Permissions::READ, 1),
				(Permissions::WRITE, 2),
				(Permissions::EXECUTE, 4),
			] {
				assert_eq!(p.contains(permission), bits & bit != 0);
			}
		}
	}
}

fn record_for_presence(selector: u8) -> Result<Metadata<'static>, Error> {
	use alloc::borrow::Cow;
	let mut meta = Metadata::default();
	match selector {
		0 => {}
		1 => meta.xattrs.push(Xattr {
			class: XattrClass::Logical,
			name: Cow::Borrowed(b"x"),
			value: Cow::Borrowed(b""),
		}),
		2 => meta.aces.push(Ace {
			tag: AceTag::Owner,
			permissions: Permissions::default(),
			name: Cow::Borrowed(b""),
		}),
		3 => {
			meta.native_acl = Some(NativeAcl {
				origin: Os::Linux,
				bytes: Cow::Borrowed(b""),
			})
		}
		4 => meta.times.mtime = Some(Time { sec: 0, nsec: 0 }),
		5 => meta.times.atime = Some(Time { sec: 0, nsec: 0 }),
		6 => meta.times.btime = Some(Time { sec: 0, nsec: 0 }),
		7 => meta.finder_flags = 1,
		8 => meta.finder_info = Some([0; 32]),
		9 => meta.holes.push(Hole {
			offset: 0,
			length: 1,
		}),
		10 => meta.hardlink_to = Some(Cow::Borrowed(b"")),
		_ => return Err(Error::BadMetadata),
	}
	Ok(meta)
}

#[test]
fn metadata_presence_distinguishes_absence_from_present_zero_values() {
	let mut reference = Reference::start();
	for selector in 0..=255u8 {
		compare(
			&mut reference,
			record_for_presence(selector).map(|m| m.is_empty()),
			11,
			&[selector],
			|empty| vec![u8::from(empty)],
		);
	}
	let empty = Metadata::default();
	assert_eq!(
		(
			empty.xattrs.capacity(),
			empty.aces.capacity(),
			empty.holes.capacity()
		),
		(0, 0, 0)
	);
}
