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
