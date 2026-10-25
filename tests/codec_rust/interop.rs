//! Candidate codec checks only; the shipped difz implementation is unchanged.
#![forbid(unsafe_code)]

#[cfg(test)]
mod tests {
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

	fn rust_frame(source: &[u8], target: &[u8], window_override: Option<u32>) -> Vec<u8> {
		rust_frame_options(
			source,
			target,
			window_override,
			rusty_zstd::AdvancedOptions {
				ldm: rusty_zstd::LdmParams::enabled(),
				..Default::default()
			},
		)
	}

	fn rust_frame_options(
		source: &[u8],
		target: &[u8],
		window_override: Option<u32>,
		options: rusty_zstd::AdvancedOptions,
	) -> Vec<u8> {
		let span = source.len().max(target.len()) as u64;
		let window = (64 - span.leading_zeros()).clamp(10, 31);
		let mut parameters = rusty_zstd::compression_params(9, Some(target.len() as u64)).unwrap();
		parameters.window_log = window_override.unwrap_or(window);
		rusty_zstd::compress_with_advanced(target, parameters, false, None, source, false, options)
			.unwrap()
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
		let restored = rusty_zstd::decompress_using_prefix_with(
			&native[HEADER_LEN..],
			source,
			rusty_zstd::DecompressOptions {
				window_max: 1 << 31,
				force_ignore_checksum: false,
			},
		)
		.unwrap();
		assert_eq!(restored, target, "Rust must decode the native prefix frame");

		let frame = rust_frame(source, target, window);
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
		let restored = rusty_zstd::decompress_using_prefix_with(
			&frame,
			source,
			rusty_zstd::DecompressOptions {
				window_max: 1 << 31,
				force_ignore_checksum: false,
			},
		)
		.unwrap();
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
		let all: Vec<u8> = (0..=255).collect();
		for (source, target) in [
			(&[][..], &[][..]),
			(&[][..], &all),
			(&all, &[][..]),
			(&b"alpha\0beta\xff"[..], &b"alpha\0BETA\x80\0"[..]),
		] {
			cross_apply(source, target, None);
		}
		let source = random_bytes(1 << 20);
		let mut scattered = source.clone();
		for byte in scattered.iter_mut().step_by(4093) {
			*byte ^= 1;
		}
		cross_apply(&source, &scattered, None);
		let mut moved = source.clone();
		moved.rotate_left(source.len() / 4);
		cross_apply(&source, &moved, None);
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
