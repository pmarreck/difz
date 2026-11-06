use super::{HEADER_LEN, Header, HeaderError};
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

#[path = "file_tests.rs"]
mod file_tests;

fn sample() -> Header {
	Header {
		source_hash: std::array::from_fn(|i| i as u8),
		target_hash: std::array::from_fn(|i| 255 - i as u8),
		source_len: 0x0102_0304_0506_0708,
		target_len: 0x1112_1314_1516_1718,
	}
}

#[test]
fn known_wire_layout_and_borrowed_payload() {
	let header = sample();
	let mut expected = b"ZDIF\x04".to_vec();
	expected.extend(0u8..32);
	expected.extend((224u8..=255).rev());
	expected.extend([8, 7, 6, 5, 4, 3, 2, 1, 24, 23, 22, 21, 20, 19, 18, 17]);
	assert_eq!(HEADER_LEN, 85);
	assert_eq!(header.encode().as_slice(), expected);
	let payload = [0, 255, 128, 1];
	expected.extend(payload);
	let (decoded, remaining) = Header::decode_prefix(&expected).unwrap();
	assert_eq!(decoded, header);
	assert_eq!(remaining, payload);
	assert_eq!(remaining.as_ptr(), expected[HEADER_LEN..].as_ptr());
}

#[test]
fn every_header_truncation_is_a_recoverable_error() {
	let bytes = sample().encode();
	for length in 0..HEADER_LEN {
		let expected = if length < 5 {
			HeaderError::InvalidMagic
		} else {
			HeaderError::Truncated
		};
		assert_eq!(
			Header::decode_prefix(&bytes[..length]),
			Err(expected),
			"length={length}"
		);
	}
	assert_eq!(Header::decode_prefix(&bytes), Ok((sample(), &[][..])));
}

#[test]
fn magic_and_version_are_classified_over_the_complete_byte_domain() {
	let bytes = sample().encode();
	for offset in 0..5 {
		for value in 0..=255u8 {
			let mut candidate = bytes;
			candidate[offset] = value;
			let result = Header::decode_prefix(&candidate);
			if value == bytes[offset] {
				assert_eq!(result, Ok((sample(), &[][..])));
			} else {
				assert_eq!(
					result,
					Err(HeaderError::InvalidMagic),
					"offset={offset} value={value}"
				);
			}
		}
	}
}

#[test]
fn digest_bytes_round_trip_in_both_directions() {
	let baseline = sample();
	for digest in 0..2 {
		for index in 0..32 {
			for value in 0..=255u8 {
				let mut header = baseline;
				match digest {
					0 => header.source_hash[index] = value,
					1 => header.target_hash[index] = value,
					_ => unreachable!(),
				}
				let bytes = header.encode();
				assert_eq!(bytes[5 + digest * 32 + index], value);
				let (decoded, remaining) = Header::decode_prefix(&bytes).unwrap();
				assert_eq!(decoded, header);
				assert!(remaining.is_empty());
				assert_eq!(decoded.encode(), bytes);
			}
		}
	}
}

#[test]
fn wire_lengths_preserve_u64_values_without_allocating_output() {
	// Parsing metadata does not authorize allocation or codec window sizes.
	let lengths = [
		0,
		1,
		255,
		256,
		(1 << 31) - 1,
		1 << 31,
		(1 << 31) + 1,
		u64::MAX,
	];
	for source_len in lengths {
		for target_len in lengths {
			let header = Header {
				source_len,
				target_len,
				..sample()
			};
			let bytes = header.encode();
			assert_eq!(Header::decode_prefix(&bytes), Ok((header, &[][..])));
		}
	}
}

struct Scratch(PathBuf);

impl Scratch {
	fn new() -> Self {
		static NEXT: AtomicU64 = AtomicU64::new(0);
		let path = std::env::temp_dir().join(format!(
			"difz-rust-header-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		// A preexisting path is refused; only a successful creation grants cleanup ownership.
		fs::create_dir(&path).unwrap();
		Self(path)
	}
}

impl Drop for Scratch {
	fn drop(&mut self) {
		let _ = fs::remove_dir_all(&self.0);
	}
}

fn run(command: &mut Command) -> Vec<u8> {
	let output = command.output().unwrap();
	assert!(
		output.status.success(),
		"command failed: {}",
		String::from_utf8_lossy(&output.stderr)
	);
	output.stdout
}

#[test]
fn native_headers_match_independent_hashes_and_rust_headers_cross_apply() {
	let oracle =
		std::env::var_os("DIFZ_ORACLE").expect("the Nix check must supply its native reference");
	let blake3 = std::env::var_os("B3SUM").expect("the Nix check must supply independent BLAKE3");
	let cases = [
		(Vec::new(), Vec::new()),
		(Vec::new(), vec![0, 255, 128, 0, 1]),
		(vec![255, 0, 128], Vec::new()),
		(
			(0..511).map(|i| (i % 256) as u8).collect(),
			(0..300).map(|i| ((i + 7) % 256) as u8).collect(),
		),
	];
	for (source, target) in cases {
		let scratch = Scratch::new();
		let source_path = scratch.0.join("source with spaces");
		let target_path = scratch.0.join("target-café");
		let native_patch = scratch.0.join("native.patch");
		let rust_patch = scratch.0.join("rust-header.patch");
		let output_path = scratch.0.join("output");
		fs::write(&source_path, &source).unwrap();
		fs::write(&target_path, &target).unwrap();
		run(Command::new(&oracle)
			.arg("--no-progress")
			.arg(&source_path)
			.arg(&target_path)
			.arg("-o")
			.arg(&native_patch));
		let native = fs::read(&native_patch).unwrap();
		let (parsed, payload) = Header::decode_prefix(&native).unwrap();
		let source_hash: [u8; 32] = run(Command::new(&blake3).arg("--raw").arg(&source_path))
			.try_into()
			.unwrap();
		let target_hash: [u8; 32] = run(Command::new(&blake3).arg("--raw").arg(&target_path))
			.try_into()
			.unwrap();
		let expected = Header {
			source_hash,
			target_hash,
			source_len: source.len() as u64,
			target_len: target.len() as u64,
		};
		assert_eq!(parsed, expected);
		assert!(!payload.is_empty());
		assert_eq!(expected.encode().as_slice(), &native[..HEADER_LEN]);
		let mut rebuilt = expected.encode().to_vec();
		rebuilt.extend(payload);
		fs::write(&rust_patch, rebuilt).unwrap();
		run(Command::new(&oracle)
			.arg("--patch")
			.arg("--no-progress")
			.arg(&source_path)
			.arg(&rust_patch)
			.arg("-o")
			.arg(&output_path));
		assert_eq!(fs::read(&output_path).unwrap(), target);
		assert_eq!(fs::read(&source_path).unwrap(), source);
	}
}
