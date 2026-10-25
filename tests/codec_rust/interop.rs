//! Candidate codec checks only; the shipped difz implementation is unchanged.
#![forbid(unsafe_code)]

pub mod codecs;

#[cfg(test)]
mod tests {
	use crate::codecs::{
		rust_decode, rust_frame, rust_frame_options, structured_decode, structured_decode_into,
		structured_frame,
	};
	use std::path::{Path, PathBuf};
	use std::process::{Command, Output};
	use std::sync::atomic::{AtomicUsize, Ordering};

	const HEADER_LEN: usize = 85;
	static NEXT_FIXTURE: AtomicUsize = AtomicUsize::new(0);

	struct Fixture(PathBuf);
	impl Fixture {
		fn new() -> Self {
			let path = std::env::temp_dir().join(format!(
				"difz-codec-{}-{}",
				std::process::id(),
				NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
			));
			std::fs::create_dir(&path).unwrap();
			Self(path)
		}
		fn path(&self, name: &str) -> PathBuf {
			self.0.join(name)
		}
	}
	impl Drop for Fixture {
		fn drop(&mut self) {
			std::fs::remove_dir_all(&self.0).expect("clean owned codec fixture");
		}
	}

	fn oracle(args: &[&std::ffi::OsStr]) -> Output {
		let executable = std::env::var_os("DIFZ_ORACLE")
			.expect("DIFZ_ORACLE must name the independently built Zig executable");
		Command::new(executable)
			.arg("--no-progress")
			.args(args)
			.output()
			.expect("run Zig oracle")
	}
	fn require_success(result: Output) {
		assert!(
			result.status.success(),
			"oracle failed: {}",
			String::from_utf8_lossy(&result.stderr)
		);
		assert!(
			result.stdout.is_empty(),
			"named-output operation wrote to stdout"
		);
	}

	fn random_bytes(len: usize) -> Vec<u8> {
		let mut seed = 42_u64;
		(0..len)
			.map(|_| {
				seed ^= seed << 13;
				seed ^= seed >> 7;
				seed ^= seed << 17;
				(seed >> 24) as u8
			})
			.collect()
	}

	fn apply_native(fixture: &Fixture, source: &Path, patch: &[u8], name: &str) -> PathBuf {
		let patch_path = fixture.path(&format!("{name}.zdif"));
		let output = fixture.path(&format!("{name}.out"));
		std::fs::write(&patch_path, patch).unwrap();
		require_success(oracle(&[
			"--patch".as_ref(),
			source.as_os_str(),
			patch_path.as_os_str(),
			"-o".as_ref(),
			output.as_os_str(),
		]));
		output
	}

	fn cross_apply(source: &[u8], target: &[u8], window: Option<u32>) -> Vec<u8> {
		cross_apply_codec(source, target, window, rust_frame, rust_decode)
	}

	fn cross_apply_codec(
		source: &[u8],
		target: &[u8],
		window: Option<u32>,
		encode: fn(&[u8], &[u8], Option<u32>) -> Vec<u8>,
		decode: fn(&[u8], &[u8], usize) -> Vec<u8>,
	) -> Vec<u8> {
		let fixture = Fixture::new();
		let source_path = fixture.path("source-δ.bin");
		let target_path = fixture.path("target with spaces.bin");
		let native_path = fixture.path("native.zdif");
		std::fs::write(&source_path, source).unwrap();
		std::fs::write(&target_path, target).unwrap();
		require_success(oracle(&[
			source_path.as_os_str(),
			target_path.as_os_str(),
			"-o".as_ref(),
			native_path.as_os_str(),
		]));
		let native = std::fs::read(&native_path).unwrap();
		assert_eq!(&native[..5], b"ZDIF\x04");
		let restored = decode(&native[HEADER_LEN..], source, target.len());
		assert_eq!(restored, target, "Rust must decode the native prefix frame");

		let frame = encode(source, target, window);
		let header = match rusty_zstd::get_frame_header(&frame).unwrap() {
			rusty_zstd::FrameKind::Zstd(header) => header,
			_ => panic!("encoder did not produce a Zstandard frame"),
		};
		assert_eq!(
			header.dict_id, None,
			"a raw binary prefix must not require a trained-dictionary ID"
		);
		assert_eq!(header.content_size, Some(target.len() as u64));
		// Borrow only the native oracle's independently computed container header.
		// The Rust frame must satisfy its source/target hashes on native apply.
		let mut combined = native[..HEADER_LEN].to_vec();
		combined.extend_from_slice(&frame);
		let rebuilt = apply_native(&fixture, &source_path, &combined, "rust-frame");
		assert_eq!(
			std::fs::read(rebuilt).unwrap(),
			target,
			"native difz must decode the Rust prefix frame"
		);
		let restored = decode(&frame, source, target.len());
		assert_eq!(
			restored, target,
			"Rust must decode the independently accepted frame"
		);

		let mut wrong = source.to_vec();
		if wrong.is_empty() {
			wrong.push(1);
		} else {
			wrong[0] ^= 1;
		}
		let wrong_path = fixture.path("wrong-source.bin");
		let invalid_output = fixture.path("invalid.out");
		let combined_path = fixture.path("rust-frame.zdif");
		std::fs::write(&wrong_path, wrong).unwrap();
		let rejected = oracle(&[
			"--patch".as_ref(),
			wrong_path.as_os_str(),
			combined_path.as_os_str(),
			"-o".as_ref(),
			invalid_output.as_os_str(),
		]);
		assert!(!rejected.status.success());
		assert!(!invalid_output.exists());

		combined[37] ^= 1; // Must-detect target identity mutation.
		let corrupt_path = fixture.path("corrupt.zdif");
		std::fs::write(&corrupt_path, combined).unwrap();
		let rejected = oracle(&[
			"--patch".as_ref(),
			source_path.as_os_str(),
			corrupt_path.as_os_str(),
			"-o".as_ref(),
			invalid_output.as_os_str(),
		]);
		assert!(!rejected.status.success());
		assert!(!invalid_output.exists());
		frame
	}

	#[test]
	fn both_implementations_cross_apply_empty_binary_and_changed_inputs() {
		basic_cross_apply(rust_frame, rust_decode);
	}

	fn basic_cross_apply(
		encode: fn(&[u8], &[u8], Option<u32>) -> Vec<u8>,
		decode: fn(&[u8], &[u8], usize) -> Vec<u8>,
	) {
		let all: Vec<u8> = (0..=255).collect();
		for (source, target) in [
			(&[][..], &[][..]),
			(&[][..], &all),
			(&all, &[][..]),
			(&b"alpha\0beta\xff"[..], &b"alpha\0BETA\x80\0"[..]),
		] {
			cross_apply_codec(source, target, None, encode, decode);
		}
		let source = random_bytes(1 << 20);
		let mut scattered = source.clone();
		for byte in scattered.iter_mut().step_by(4093) {
			*byte ^= 1;
		}
		cross_apply_codec(&source, &scattered, None, encode, decode);
		let mut moved = source.clone();
		moved.rotate_left(source.len() / 4);
		cross_apply_codec(&source, &moved, None, encode, decode);
	}

	#[test]
	fn structured_cross_applies_empty_binary_and_changed_inputs() {
		basic_cross_apply(structured_frame, structured_decode);
	}

	#[test]
	fn structured_reaches_distant_raw_prefix_bytes_even_with_dictionary_magic() {
		let mut source = random_bytes(2 << 20);
		source[..4].copy_from_slice(&[0x37, 0xa4, 0x30, 0xec]);
		let target = &source[..65536];
		let frame = cross_apply_codec(&source, target, None, structured_frame, structured_decode);
		assert!(frame.len() < target.len() / 8);
		assert!(structured_frame(&[], target, None).len() >= target.len() / 8);
		let mut output = vec![0; target.len()];
		assert!(structured_decode_into(&frame, &[], &mut output, 1 << 22).is_err());
	}

	#[test]
	fn structured_prefix_decode_obeys_output_slices_and_verifies_checksums() {
		use structured_zstd::decoding::{Dictionary, DictionaryHandle, FrameDecoder};
		const GUARD: usize = 32;
		let source = random_bytes(65536);
		let mut target = source.clone();
		target[100] ^= 1;
		let mut parameters = rusty_zstd::compression_params(9, Some(target.len() as u64)).unwrap();
		parameters.window_log = 17;
		let frame = rusty_zstd::compress_with_advanced(
			&target,
			parameters,
			true,
			None,
			&source,
			false,
			rusty_zstd::AdvancedOptions::default(),
		)
		.unwrap();
		for limit in [0, 1, target.len() - 1, target.len(), target.len() + 16] {
			let mut guarded = vec![0xa5; limit + 2 * GUARD];
			let result = structured_decode_into(
				&frame,
				&source,
				&mut guarded[GUARD..GUARD + limit],
				1 << 22,
			);
			assert!(guarded[..GUARD].iter().all(|&byte| byte == 0xa5));
			assert!(guarded[GUARD + limit..].iter().all(|&byte| byte == 0xa5));
			if limit < target.len() {
				assert!(result.is_err(), "insufficient output must fail");
			} else {
				assert_eq!(result.unwrap(), target.len());
				assert_eq!(&guarded[GUARD..GUARD + target.len()], target);
				assert!(guarded[GUARD + target.len()..]
					.iter()
					.all(|&byte| byte == 0xa5));
			}
		}
		let mut corrupt = frame;
		*corrupt.last_mut().unwrap() ^= 1;
		let mut output = vec![0; target.len()];
		assert!(structured_decode_into(&corrupt, &source, &mut output, 1 << 22).is_err());
		// The default computes but does not enforce the checksum. Prove the
		// explicit Verify setting above changes the outcome for the same bytes.
		let mut default_decoder = FrameDecoder::new();
		let dictionary =
			DictionaryHandle::from_dictionary(Dictionary::from_raw_content(0, source).unwrap());
		assert_eq!(
			default_decoder
				.decode_all_with_dict_handle(&corrupt, &mut output, &dictionary)
				.unwrap(),
			target.len()
		);
		assert_eq!(output, target);
	}

	#[test]
	fn structured_encoder_and_decoder_have_distinct_window_limits() {
		use structured_zstd::decoding::{Dictionary, DictionaryHandle, FrameDecoder};
		use structured_zstd::encoding::{CompressionLevel, CompressionParameters};
		assert!(CompressionParameters::builder(CompressionLevel::Level(9))
			.window_log(30)
			.build()
			.is_ok());
		assert!(CompressionParameters::builder(CompressionLevel::Level(9))
			.window_log(31)
			.build()
			.is_err());
		let source = random_bytes(65536);
		let target = &source[..4096];
		let frame = rust_frame(&source, target, Some(31));
		let mut decoder = FrameDecoder::new();
		decoder.set_max_window_size(1 << 20).unwrap();
		let dictionary = DictionaryHandle::from_dictionary(
			Dictionary::from_raw_content(0, source.clone()).unwrap(),
		);
		let mut output = vec![0; target.len()];
		assert_eq!(
			decoder
				.decode_all_with_dict_handle(&frame, &mut output, &dictionary)
				.unwrap(),
			target.len()
		);
		assert_eq!(output, target);
		assert!(
			decoder.workspace_size() < 16 << 20,
			"caller-owned output must not reserve the advertised 2 GiB window"
		);
		// The retained-window streaming path does enforce this same ceiling.
		let mut input = frame.as_slice();
		assert!(decoder.reset(&mut input).is_err());
	}

	#[test]
	fn prefix_reaches_old_source_bytes_beyond_a_payload_sized_window() {
		let mut source = random_bytes(2 << 20);
		// A binary prefix must remain raw even if it starts with dictionary magic.
		source[..4].copy_from_slice(&[0x37, 0xa4, 0x30, 0xec]);
		let target = &source[..65536];
		let frame = cross_apply(&source, target, None);
		assert!(
			frame.len() < target.len() / 8,
			"the source prefix was not effectively used: {} bytes",
			frame.len()
		);
		// Independent negative control: ordinary compression cannot pass this gate.
		let without_prefix = rusty_zstd::compress(target, 9).unwrap();
		assert!(without_prefix.len() >= target.len() / 8);
	}

	#[test]
	fn a_two_gib_window_is_interoperable_without_a_two_gib_fixture() {
		let source = random_bytes(65536);
		let frame = cross_apply(&source, &source[..4096], Some(31));
		match rusty_zstd::get_frame_header(&frame).unwrap() {
			rusty_zstd::FrameKind::Zstd(header) => assert_eq!(header.window_size, 1 << 31),
			_ => panic!("not a Zstandard frame"),
		}
	}

	#[test]
	fn multi_job_frames_reconstruct_but_only_the_first_reuses_the_original_prefix() {
		// Characterize the candidate before adoption: this mode does not meet
		// difz's current single-frame encoding contract or full-prefix reach.
		const JOB: usize = 512 * 1024;
		let source = random_bytes(4 * JOB);
		let mut target = source.clone();
		for byte in target.iter_mut().skip(JOB / 2).step_by(JOB) {
			*byte ^= 1;
		}
		let fixture = Fixture::new();
		let source_path = fixture.path("source");
		let target_path = fixture.path("target");
		let native_path = fixture.path("native.zdif");
		std::fs::write(&source_path, &source).unwrap();
		std::fs::write(&target_path, &target).unwrap();
		require_success(oracle(&[
			source_path.as_os_str(),
			target_path.as_os_str(),
			"-o".as_ref(),
			native_path.as_os_str(),
		]));
		let native = std::fs::read(&native_path).unwrap();
		let single = rust_frame(&source, &target, None);
		assert!(single.len() < source.len() / 8);
		let options = |workers| rusty_zstd::AdvancedOptions {
			ldm: rusty_zstd::LdmParams::enabled(),
			nb_workers: workers,
			job_size: JOB,
			overlap_log: 1,
			..Default::default()
		};
		let threaded = rust_frame_options(&source, &target, None, options(1));
		for workers in [4, 4] {
			assert_eq!(
				rust_frame_options(&source, &target, None, options(workers)),
				threaded,
				"job order and bytes must not depend on worker scheduling"
			);
		}
		let mut remaining = threaded.as_slice();
		let mut frames = Vec::new();
		while !remaining.is_empty() {
			let length = rusty_zstd::find_frame_compressed_size(remaining).unwrap();
			assert!(length > 0 && length <= remaining.len());
			frames.push(&remaining[..length]);
			remaining = &remaining[length..];
		}
		assert_eq!(frames.len(), 4, "must exercise four actual frames/jobs");
		assert!(frames[0].len() < JOB / 8);
		let first = rusty_zstd::decompress_using_prefix(frames[0], &source).unwrap();
		assert_eq!(first, target[..JOB]);
		assert!(rusty_zstd::decompress(frames[0]).is_err());
		for (index, frame) in frames.iter().enumerate().skip(1) {
			// A decoder given no dictionary still reconstructs later jobs. This
			// negative control demonstrates their lack of source-prefix use.
			assert_eq!(
				rusty_zstd::decompress(frame).unwrap(),
				target[index * JOB..(index + 1) * JOB]
			);
			assert!(frame.len() > JOB / 2);
		}
		assert!(threaded.len() > source.len() / 2);
		assert_eq!(
			rusty_zstd::decompress_using_prefix_with(
				&threaded,
				&source,
				rusty_zstd::DecompressOptions {
					window_max: 1 << 22,
					force_ignore_checksum: false,
				},
			)
			.unwrap(),
			target
		);
		assert!(
			rusty_zstd::decompress_using_prefix_with(
				&threaded,
				&source,
				rusty_zstd::DecompressOptions {
					window_max: 1 << 20,
					force_ignore_checksum: false,
				},
			)
			.is_err(),
			"an advertised window above the caller's cap must be rejected"
		);
		assert_eq!(
			rusty_zstd::decompress_using_prefix(&threaded, &source).unwrap(),
			target
		);
		let mut combined = native[..HEADER_LEN].to_vec();
		combined.extend_from_slice(&threaded);
		let rebuilt = apply_native(&fixture, &source_path, &combined, "multi-frame");
		assert_eq!(std::fs::read(rebuilt).unwrap(), target);
	}

	#[test]
	fn zstdz_multiple_jobs_keep_one_frame_and_reach_the_whole_source() {
		const JOB: usize = 512 * 1024;
		let source = random_bytes(4 * JOB);
		let mut target = source.clone();
		for byte in target.iter_mut().skip(JOB / 2).step_by(JOB) {
			*byte ^= 1;
		}
		let fixture = Fixture::new();
		let source_path = fixture.path("source");
		let target_path = fixture.path("target");
		std::fs::write(&source_path, &source).unwrap();
		std::fs::write(&target_path, &target).unwrap();
		let executable = std::env::var_os("ZSTD_CLI")
			.expect("ZSTD_CLI must name the Nix-prepared pinned zstdz CLI");
		let mut reference = None;
		for (index, mode) in ["--single-thread", "-T1", "-T4", "-T4"].iter().enumerate() {
			let patch = fixture.path(&format!("frame-{index}.zst"));
			let result = Command::new(&executable)
				.args(["-q", "-f", "-9", mode, "--jobsize=524288"])
				.arg(format!("--patch-from={}", source_path.display()))
				.arg(&target_path)
				.arg("-o")
				.arg(&patch)
				.output()
				.unwrap();
			require_success(result);
			let frame = std::fs::read(patch).unwrap();
			assert_eq!(
				rusty_zstd::find_frame_compressed_size(&frame).unwrap(),
				frame.len()
			);
			assert!(frame.len() < source.len() / 8);
			assert_eq!(
				rusty_zstd::decompress_using_prefix(&frame, &source).unwrap(),
				target
			);
			if index > 0 {
				if let Some(previous) = &reference {
					assert_eq!(
						&frame, previous,
						"worker count and scheduling must preserve bytes"
					);
				} else {
					reference = Some(frame);
				}
			}
		}
		let plain = fixture.path("no-prefix.zst");
		require_success(
			Command::new(executable)
				.args(["-q", "-f", "-9", "--single-thread"])
				.arg(&target_path)
				.arg("-o")
				.arg(&plain)
				.output()
				.unwrap(),
		);
		assert!(std::fs::metadata(plain).unwrap().len() >= (source.len() / 8) as u64);
	}
}
