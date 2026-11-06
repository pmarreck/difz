use super::{Scratch, run};
use crate::{
	HEADER_LEN, Header,
	file::{self, Error},
};
use std::{fs, process::Command};

#[test]
fn file_codec_cross_applies_with_the_native_reference() {
	let oracle = std::env::var_os("DIFZ_ORACLE").unwrap();
	let all: Vec<u8> = (0..=255).collect();
	let repeated = all.repeat(2048);
	let mut edited = repeated.clone();
	for byte in edited.iter_mut().step_by(4093) {
		*byte ^= 1;
	}
	let mut moved = repeated.clone();
	moved.rotate_left(12345);
	let mut cases = vec![
		(Vec::new(), Vec::new()),
		(Vec::new(), all.clone()),
		(all.clone(), Vec::new()),
		(all.clone(), all.clone()),
		(repeated.clone(), edited),
		(repeated.clone(), moved),
	];
	// Retain native equality at the small-input hash-table/LDM transitions.
	for n in [1 << 18, 1 << 19, 1 << 20, 1 << 21] {
		let random = std::env::var_os("DIFZ_RANDOM").unwrap();
		let source = run(Command::new(random).args(["--seed", "41", "-b", "-c", &n.to_string()]));
		assert_eq!(source.len(), n);
		let mut target = source.clone();
		for byte in target.iter_mut().step_by(4093) {
			*byte ^= 1;
		}
		cases.push((source, target));
	}
	for (source, target) in cases {
		let scratch = Scratch::new();
		let a = scratch.0.join("source with spaces");
		let b = scratch.0.join("target-café");
		let patch_path = scratch.0.join("native.patch");
		let rust_path = scratch.0.join("rust.patch");
		let output = scratch.0.join("output");
		fs::write(&a, &source).unwrap();
		fs::write(&b, &target).unwrap();
		run(Command::new(&oracle)
			.arg("--no-progress")
			.arg(&a)
			.arg(&b)
			.arg("-o")
			.arg(&patch_path));
		let native = fs::read(&patch_path).unwrap();
		assert_eq!(file::apply(&source, &native, 0).unwrap(), target);
		let rust = file::encode(&source, &target).unwrap();
		assert_eq!(
			rust,
			file::encode(&source, &target).unwrap(),
			"deterministic encoding"
		);
		assert_eq!(
			rust, native,
			"the same pinned codec and parameters must agree on these fixtures"
		);
		fs::write(&rust_path, &rust).unwrap();
		run(Command::new(&oracle)
			.arg("--patch")
			.arg("--no-progress")
			.arg(&a)
			.arg(&rust_path)
			.arg("-o")
			.arg(&output));
		assert_eq!(fs::read(&output).unwrap(), target);
		assert_eq!(file::apply(&source, &rust, target.len()).unwrap(), target);
		assert_eq!(fs::read(&a).unwrap(), source);
	}
}

#[test]
fn file_rejections_preserve_native_precedence_and_resource_bounds() {
	let source = b"old binary\0\xff";
	let target = b"new binary\0\x80";
	let patch = file::encode(source, target).unwrap();
	assert_eq!(file::apply(b"wrong", &patch, 0), Err(Error::SizeMismatch));
	let mut wrong = source.to_vec();
	wrong[0] ^= 1;
	assert_eq!(
		file::apply(&wrong, &patch, 0),
		Err(Error::SourceHashMismatch)
	);
	assert_eq!(
		file::apply(source, &patch, target.len() - 1),
		Err(Error::ResourceLimitExceeded)
	);
	for end in 0..patch.len() {
		let result = file::apply(source, &patch[..end], 0);
		let expected = if end < 5 {
			Error::InvalidMagic
		} else if end < HEADER_LEN {
			Error::Truncated
		} else {
			Error::DecompressionFailed
		};
		assert_eq!(result, Err(expected), "truncation {end}");
	}
	let mut changed = patch.clone();
	changed[37] ^= 1;
	assert_eq!(
		file::apply(source, &changed, 0),
		Err(Error::TargetHashMismatch)
	);
	let mut changed = patch.clone();
	changed[5] ^= 1;
	assert_eq!(
		file::apply(source, &changed, 0),
		Err(Error::SourceHashMismatch)
	);
	let (mut header, frame) = Header::decode_prefix(&patch).unwrap();
	header.target_len = u64::MAX;
	let mut huge = header.encode().to_vec();
	huge.extend(frame);
	assert_eq!(
		file::apply(source, &huge, 1),
		Err(Error::ResourceLimitExceeded)
	);
	assert_eq!(file::apply(source, &huge, 0), Err(Error::WindowTooLarge));
	assert_eq!(
		file::apply(&wrong, &huge, 0),
		Err(Error::SourceHashMismatch)
	);
}

#[test]
fn window_contract_exhausts_power_boundaries_without_large_allocations() {
	for power in 0..=31 {
		for n in [(1u64 << power) - 1, 1u64 << power, (1u64 << power) + 1] {
			let expected = if n > 1 << 31 {
				Err(Error::WindowTooLarge)
			} else {
				Ok((64 - n.leading_zeros()).clamp(10, 31))
			};
			assert_eq!(file::window_log(0, n), expected);
			assert_eq!(file::window_log(n, 0), expected);
		}
	}
	assert_eq!(file::window_log(u64::MAX, 0), Err(Error::WindowTooLarge));
}

#[test]
fn concurrent_operations_have_independent_native_contexts() {
	std::thread::scope(|scope| {
		for worker in 0..4 {
			scope.spawn(move || {
				let source = vec![worker; 8192];
				let mut target = source.clone();
				target[worker as usize] ^= 0xff;
				for _ in 0..8 {
					let patch = file::encode(&source, &target).unwrap();
					assert_eq!(file::apply(&source, &patch, 0).unwrap(), target);
				}
			});
		}
	});
}

#[test]
fn raw_dictionary_magic_and_distant_source_bytes_require_the_prefix() {
	let random = std::env::var_os("DIFZ_RANDOM").unwrap();
	let mut source = run(Command::new(random).args(["--seed", "41", "-b", "-c", "2097152"]));
	assert_eq!(source.len(), 1 << 21);
	source[..4].copy_from_slice(&[0x37, 0xa4, 0x30, 0xec]);
	let mut target = source[..65536].to_vec();
	target[127] ^= 1;
	let patch = file::encode(&source, &target).unwrap();
	assert!(patch.len() < target.len() / 8);
	assert!(file::encode(&[], &target).unwrap().len() > target.len() / 2);
	assert!(difz_zstdz::decode(&[], &patch[HEADER_LEN..], target.len()).is_err());
	assert_eq!(file::apply(&source, &patch, 0).unwrap(), target);
}
