use cpu_time::ProcessTime;
use difz_core::file::{self, Operation};
use serde_json::json;
use std::{fs, hint::black_box, path::PathBuf, process::Command, time::Instant};

const TARGET_SAMPLE_NS: u128 = 100_000_000;
const MAX_ITERATIONS: usize = 512;
fn calibrated_iterations(cpu_ns: u128) -> usize {
	TARGET_SAMPLE_NS
		.div_ceil(cpu_ns)
		.clamp(1, MAX_ITERATIONS as u128) as usize
}

fn random_seed_argument(seed: &str) -> String {
	if seed.len() == 32 && seed.bytes().all(|byte| byte.is_ascii_hexdigit()) {
		format!("0x{seed}")
	} else {
		seed.to_owned()
	}
}

fn provider_bytes(seed: &str, length: usize) -> Vec<u8> {
	let random = Command::new(env!("DIFZ_RANDOM"))
		.args(["--seed", seed, "-b", "-c", &length.to_string()])
		.output()
		.unwrap();
	assert!(
		random.status.success(),
		"{}",
		String::from_utf8_lossy(&random.stderr)
	);
	assert_eq!(random.stdout.len(), length);
	random.stdout
}

fn seeded_bytes(seed: &str, length: usize) -> Vec<u8> {
	provider_bytes(&random_seed_argument(seed), length)
}

struct Scratch(PathBuf);
impl Drop for Scratch {
	fn drop(&mut self) {
		fs::remove_dir_all(&self.0).unwrap();
	}
}

fn execute(op: Operation, source: &[u8], target: &[u8], patch: &[u8]) -> Vec<u8> {
	match op {
		Operation::Encode => file::encode(black_box(source), black_box(target)).unwrap(),
		Operation::Apply => file::apply(black_box(source), black_box(patch), 0).unwrap(),
	}
}

pub fn run(args: &[String]) {
	assert!(!cfg!(debug_assertions), "optimized probe required");
	assert_eq!(
		args.len(),
		3,
		"operation, comma-separated sizes, seed required"
	);
	let op = *Operation::ALL
		.iter()
		.find(|op| op.name() == args[0])
		.unwrap();
	let sizes: Vec<usize> = args[1].split(',').map(|n| n.parse().unwrap()).collect();
	assert!(!sizes.is_empty() && sizes.iter().all(|n| *n > 0 && *n <= 1 << 24));
	let seed = &args[2];
	let directory = std::env::temp_dir().join(format!("difz-rust-measure-{}", std::process::id()));
	fs::create_dir(&directory).unwrap(); // Refuse preexisting state; cleanup only our creation.
	let scratch = Scratch(directory);
	let mut rows = Vec::new();
	let native_parameters: serde_json::Value =
		serde_json::from_str(include_str!(env!("DIFZ_NATIVE_PARAMS"))).unwrap();
	for n in sizes {
		let source = seeded_bytes(seed, n);
		let mut target = source.clone();
		for byte in target.iter_mut().step_by(4093) {
			*byte ^= 1;
		}
		let a = scratch.0.join("source");
		let b = scratch.0.join("target");
		let p = scratch.0.join("patch");
		fs::write(&a, &source).unwrap();
		fs::write(&b, &target).unwrap();
		if p.exists() {
			fs::remove_file(&p).unwrap();
		}
		let native = Command::new(env!("DIFZ_ORACLE"))
			.arg("--no-progress")
			.arg(&a)
			.arg(&b)
			.arg("-o")
			.arg(&p)
			.output()
			.unwrap();
		assert!(
			native.status.success(),
			"{}",
			String::from_utf8_lossy(&native.stderr)
		);
		let patch = fs::read(&p).unwrap();
		let expected = match op {
			Operation::Encode => &patch,
			Operation::Apply => &target,
		};
		for _ in 0..3 {
			assert_eq!(&execute(op, &source, &target, &patch), expected);
		}
		let calibration = ProcessTime::try_now().unwrap();
		let calibrated = execute(op, &source, &target, &patch);
		let calibration_ns = calibration.try_elapsed().unwrap().as_nanos();
		assert_eq!(&calibrated, expected);
		assert!(calibration_ns > 0, "CPU clock must advance");
		let iterations = calibrated_iterations(calibration_ns);
		let mut wall_samples = Vec::new();
		let mut cpu_samples = Vec::new();
		for _ in 0..5 {
			let mut wall = 0u128;
			let mut cpu = 0u128;
			for _ in 0..iterations {
				let cpu_start = ProcessTime::try_now().unwrap();
				let wall_start = Instant::now();
				let output = execute(op, &source, &target, &patch);
				wall += wall_start.elapsed().as_nanos();
				cpu += cpu_start.try_elapsed().unwrap().as_nanos();
				assert_eq!(&output, expected); // Independent native patch/target, outside timing.
			}
			assert!(wall > 0 && cpu > 0);
			wall_samples.push(wall as f64 / iterations as f64);
			cpu_samples.push(cpu as f64 / iterations as f64);
		}
		let parameters = native_parameters
			.as_array()
			.unwrap()
			.iter()
			.find(|p| p["size"].as_u64() == Some(n as u64))
			.unwrap();
		rows.push(json!({"size":n,"native_parameters":parameters,"patch_bytes":patch.len(),"iterations_per_sample":iterations,"samples":{"wall_ns":wall_samples,"cpu_ns":cpu_samples}}));
	}
	println!(
		"{}",
		json!({"schema":"performance-measurement/v1","correct":true,"build_mode":"release","runtime":"Rust-1.94.1/zstdz","operation":op.name(),"seed":seed.to_string(),"fixture":"seeded-random-source-scattered-edits-v1","clock":"Instant monotonic wall; ProcessTime all-thread CPU; per-call normalized; validation and buffer destruction outside timing","rows":rows})
	);
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn seed_transport_matches_the_provider_and_retains_high_bits() {
		for (reported, argument) in [
			("41", "41"),
			("18446744073709551615", "0xffffffffffffffff"),
			(
				"c142957203c7288e5c8e11016735fcee",
				"0xc142957203c7288e5c8e11016735fcee",
			),
			(
				"00000000000000010000000000000001",
				"0x00000000000000010000000000000001",
			),
			("0xabcdef", "0xabcdef"),
		] {
			assert_eq!(seeded_bytes(reported, 64), provider_bytes(argument, 64));
		}
		assert_ne!(
			seeded_bytes("00000000000000010000000000000001", 64),
			seeded_bytes("00000000000000020000000000000001", 64)
		);
	}
	#[test]
	fn calibration_meets_the_work_target_with_the_smallest_bounded_batch() {
		for duration in [
			1,
			100,
			100_000,
			1_000_000,
			13_000_000,
			20_000_000,
			70_000_000,
			100_000_000,
			100_000_001,
			1_000_000_000,
			30_000_000_000,
		] {
			let count = calibrated_iterations(duration);
			assert!((1..=MAX_ITERATIONS).contains(&count));
			if duration * (MAX_ITERATIONS as u128) < TARGET_SAMPLE_NS {
				assert_eq!(count, MAX_ITERATIONS);
			} else {
				assert!(
					(count as u128) * duration >= TARGET_SAMPLE_NS,
					"insufficient work: duration={duration}, calls={count}"
				);
				assert!(
					count == 1 || ((count - 1) as u128) * duration < TARGET_SAMPLE_NS,
					"excess work: duration={duration}, calls={count}"
				);
			}
		}
	}
}
