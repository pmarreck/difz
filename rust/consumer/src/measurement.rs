use cpu_time::ProcessTime;
use difz_core::file::{self, Operation};
use serde_json::json;
use std::{fs, hint::black_box, path::PathBuf, process::Command, time::Instant};

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
	let seed: u64 = args[2].parse().unwrap();
	let directory = std::env::temp_dir().join(format!("difz-rust-measure-{}", std::process::id()));
	fs::create_dir(&directory).unwrap(); // Refuse preexisting state; cleanup only our creation.
	let scratch = Scratch(directory);
	let mut rows = Vec::new();
	let native_parameters: serde_json::Value =
		serde_json::from_str(include_str!(env!("DIFZ_NATIVE_PARAMS"))).unwrap();
	for n in sizes {
		let random = Command::new(env!("DIFZ_RANDOM"))
			.args(["--seed", &seed.to_string(), "-b", "-c", &n.to_string()])
			.output()
			.unwrap();
		assert!(random.status.success());
		let source = random.stdout;
		assert_eq!(source.len(), n);
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
		let iterations = (100_000_000 / calibration_ns).clamp(5, 512) as usize;
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
