use super::*;
use std::{
	io::Write,
	process::{Command, Stdio},
};

fn native(mode: u32, input: &[u8]) -> Result<Vec<u8>, String> {
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

fn compare<T>(actual: Result<T, Error>, mode: u32, bytes: &[u8], encode: impl Fn(T) -> Vec<u8>) {
	let actual = actual.map(encode).map_err(|e| format!("{e:?}"));
	assert_eq!(actual, native(mode, bytes), "mode={mode} bytes={bytes:?}");
}

#[test]
fn omission_masks_and_family_names_match_the_reference_over_the_finite_domain() {
	let names = ["xattr", "acl", "timestamps", "finder", "sparse", "hardlink"];
	for mask in (0..=255u32)
		.chain((6..32).map(|bit| 1 << bit))
		.chain([u32::MAX])
	{
		compare(Omit::from_bits(mask), 0, &mask.to_le_bytes(), |omit| {
			omit.bits().to_le_bytes().to_vec()
		});
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
			compare(Omit::parse(text.as_bytes()), 1, text.as_bytes(), |omit| {
				omit.bits().to_le_bytes().to_vec()
			});
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
		compare(Omit::parse(text.as_bytes()), 1, text.as_bytes(), |omit| {
			omit.bits().to_le_bytes().to_vec()
		});
	}
	compare(Omit::parse(&[0xff]), 1, &[0xff], |omit| {
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
	let mut values = vec![None];
	for sec in [i64::MIN, -1, 0, 1, i64::MAX] {
		for nsec in [0, 1, 999_999_999, 1_000_000_000, u32::MAX] {
			values.push(Some(Time { sec, nsec }));
		}
	}
	for value in values {
		let bytes = time_bytes(value);
		compare(decode_time_override(&bytes), 2, &bytes, time_bytes);
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
		compare(decode_time_override(&bytes), 2, &bytes, time_bytes);
		compare(decode_time_override(&[flag]), 2, &[flag], time_bytes);
	}
}

#[test]
fn modification_override_binds_original_and_observed_values_with_exact_lengths() {
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
			compare(decode_modification_override(&bytes), 3, &bytes, |v| {
				encode_modification_override(v).unwrap().as_bytes().to_vec()
			});
			for length in 0..bytes.len() {
				compare(
					decode_modification_override(&bytes[..length]),
					3,
					&bytes[..length],
					|v| encode_modification_override(v).unwrap().as_bytes().to_vec(),
				);
			}
			bytes.push(0);
			compare(decode_modification_override(&bytes), 3, &bytes, |v| {
				encode_modification_override(v).unwrap().as_bytes().to_vec()
			});
		}
	}
}

#[test]
fn attribute_names_match_reference_for_binary_bytes_reserved_names_and_size_limits() {
	for byte in 0..=255u8 {
		let name = [b'a', byte, b'b'];
		for (class, mode) in [(XattrClass::Logical, 4), (XattrClass::Raw, 5)] {
			compare(validate_xattr_name(class, &name), mode, &name, |()| vec![]);
		}
	}
	for length in [0, 1, 126, 127, 128, 254, 255, 256] {
		let name = vec![b'a'; length];
		for (class, mode) in [(XattrClass::Logical, 4), (XattrClass::Raw, 5)] {
			compare(validate_xattr_name(class, &name), mode, &name, |()| vec![]);
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
				native(8, name.as_bytes()).unwrap()
			);
			for (class, mode) in [(XattrClass::Logical, 4), (XattrClass::Raw, 5)] {
				compare(
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
			validate_hardlink(path.as_bytes()),
			6,
			path.as_bytes(),
			|()| vec![],
		);
	}
	for length in [4095, 4096, 4097] {
		let path = vec![b'a'; length];
		compare(validate_hardlink(&path), 6, &path, |()| vec![]);
	}
	for byte in 0..=255u8 {
		let name = [b'a', byte, b'b'];
		compare(validate_hardlink(&name), 6, &name, |()| vec![]);
	}
	for tag in 0..=255u8 {
		for name in [b"".as_slice(), b"name", b"a/b", b"a\0b", b"\xff", b"a\\b"] {
			let mut input = vec![tag];
			input.extend(name);
			compare(
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
	assert_eq!(Os::ALL.len(), 3);
	for tag in 0..=255u8 {
		let actual = Os::try_from(tag).map(|os| vec![u8::from(raw_accepted(os, b"user.name"))]);
		let mut input = vec![tag];
		input.extend(b"user.name");
		compare(actual, 9, &input, |value| value);
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
				native(9, &input).unwrap()
			);
		}
		for length in [127, 128, 255, 256] {
			let mut input = vec![os as u8];
			input.extend(vec![b'a'; length]);
			assert_eq!(
				vec![u8::from(raw_accepted(os, &input[1..]))],
				native(9, &input).unwrap()
			);
		}
	}
}
