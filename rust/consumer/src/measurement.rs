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

struct Samples {
	iterations: usize,
	wall: Vec<f64>,
	cpu: Vec<f64>,
}

trait Clock {
	type Start;
	fn start(&mut self) -> Self::Start;
	fn elapsed(&mut self, start: Self::Start) -> (u128, u128);
}
struct NativeClock;
impl Clock for NativeClock {
	type Start = (ProcessTime, Instant);
	fn start(&mut self) -> Self::Start {
		(ProcessTime::try_now().unwrap(), Instant::now())
	}
	fn elapsed(&mut self, (cpu, wall): Self::Start) -> (u128, u128) {
		(
			wall.elapsed().as_nanos(),
			cpu.try_elapsed().unwrap().as_nanos(),
		)
	}
}
struct Sweep {
	rows: Vec<Samples>,
	order: Vec<usize>,
}
fn sample_rows<T>(
	count: usize,
	mut work: impl FnMut(usize) -> T,
	mut verify: impl FnMut(usize, &T),
	clock: &mut impl Clock,
) -> Sweep {
	assert!((1..=16).contains(&count));
	let mut rows = Vec::new();
	for row in 0..count {
		for _ in 0..3 {
			verify(row, &work(row));
		}
		let start = clock.start();
		let calibrated = work(row);
		let (_, cpu) = clock.elapsed(start);
		assert!(cpu > 0, "CPU clock must advance");
		verify(row, &calibrated);
		drop(calibrated);
		rows.push(Samples {
			iterations: calibrated_iterations(cpu),
			wall: Vec::new(),
			cpu: Vec::new(),
		});
	}
	let mut order = Vec::new();
	for round in 0..5 {
		for position in 0..count {
			let row = if round % 2 == 0 {
				(round + position) % count
			} else {
				(round + count - position) % count
			};
			order.push(row);
			let samples = &mut rows[row];
			let mut wall = 0u128;
			let mut cpu = 0u128;
			for _ in 0..samples.iterations {
				let start = clock.start();
				let output = work(row);
				let (elapsed_wall, elapsed_cpu) = clock.elapsed(start);
				wall += elapsed_wall;
				cpu += elapsed_cpu;
				verify(row, &output);
			}
			assert!(wall > 0 && cpu > 0);
			samples.wall.push(wall as f64 / samples.iterations as f64);
			samples.cpu.push(cpu as f64 / samples.iterations as f64);
		}
	}
	Sweep { rows, order }
}
#[cfg(test)]
fn sample_work<T>(mut execute: impl FnMut() -> T, mut verify: impl FnMut(&T)) -> Samples {
	sample_rows(
		1,
		|_| execute(),
		|_, output| verify(output),
		&mut NativeClock,
	)
	.rows
	.pop()
	.unwrap()
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
	struct Fixture {
		size: usize,
		source: Vec<u8>,
		target: Vec<u8>,
		patch: Vec<u8>,
		parameters: serde_json::Value,
	}
	let mut fixtures = Vec::new();
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
		let parameters = native_parameters
			.as_array()
			.unwrap()
			.iter()
			.find(|p| p["size"].as_u64() == Some(n as u64))
			.unwrap();
		fixtures.push(Fixture {
			size: n,
			source,
			target,
			patch,
			parameters: parameters.clone(),
		});
	}
	let sweep = sample_rows(
		fixtures.len(),
		|index| {
			let Fixture {
				size: _,
				source,
				target,
				patch,
				parameters: _,
			} = &fixtures[index];
			execute(op, source, target, patch)
		},
		|index, output| {
			let fixture = &fixtures[index];
			let expected = match op {
				Operation::Encode => &fixture.patch,
				Operation::Apply => &fixture.target,
			};
			assert_eq!(output, expected);
		},
		&mut NativeClock,
	);
	let sample_order: Vec<Vec<usize>> = sweep
		.order
		.chunks(fixtures.len())
		.map(|indices| indices.iter().map(|index| fixtures[*index].size).collect())
		.collect();
	let rows: Vec<_> = fixtures.iter().zip(sweep.rows).map(|(fixture, samples)| json!({"size":fixture.size,"native_parameters":fixture.parameters,"patch_bytes":fixture.patch.len(),"iterations_per_sample":samples.iterations,"samples":{"wall_ns":samples.wall,"cpu_ns":samples.cpu}})).collect();
	println!(
		"{}",
		json!({"schema":"performance-measurement/v1","correct":true,"build_mode":"release","runtime":"Rust-1.94.1/zstdz","operation":op.name(),"seed":seed.to_string(),"fixture":"seeded-random-source-scattered-edits-v2-resident-sweep","clock":"Instant monotonic wall; ProcessTime all-thread CPU; per-call normalized; validation and destruction outside timing; calibration output released; interleaved size rounds","sample_order":sample_order,"rows":rows})
	);
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn sweep_interleaves_sizes_with_clocks_validation_and_destruction_separated() {
		use std::{
			cell::{Cell, RefCell},
			rc::Rc,
		};
		struct FakeClock(Rc<Cell<u8>>);
		impl Clock for FakeClock {
			type Start = ();
			fn start(&mut self) {
				assert_eq!(self.0.replace(1), 0);
			}
			fn elapsed(&mut self, (): ()) -> (u128, u128) {
				assert_eq!(self.0.replace(0), 2);
				(TARGET_SAMPLE_NS, TARGET_SAMPLE_NS)
			}
		}
		struct Output {
			row: usize,
			live: Rc<Cell<usize>>,
			phase: Rc<Cell<u8>>,
		}
		impl Drop for Output {
			fn drop(&mut self) {
				assert_eq!(self.phase.get(), 0);
				assert_eq!(self.live.replace(0), 1);
			}
		}
		for count in 1..=8 {
			let phase = Rc::new(Cell::new(0));
			let live = Rc::new(Cell::new(0));
			let trace = RefCell::new(Vec::new());
			let sweep = sample_rows(
				count,
				|row| {
					assert_eq!(live.replace(1), 0);
					if phase.get() == 1 {
						phase.set(2);
					}
					trace.borrow_mut().push(row);
					Output {
						row,
						live: live.clone(),
						phase: phase.clone(),
					}
				},
				|row, output| {
					assert_eq!(phase.get(), 0);
					assert_eq!(row, output.row);
				},
				&mut FakeClock(phase.clone()),
			);
			assert_eq!(live.get(), 0);
			let trace = trace.into_inner();
			assert_eq!(
				&trace[..count * 4],
				&(0..count).flat_map(|row| [row; 4]).collect::<Vec<_>>()
			);
			assert_eq!(&trace[count * 4..], sweep.order);
			for round in sweep.order.chunks_exact(count) {
				let mut visited = round.to_vec();
				visited.sort_unstable();
				assert_eq!(visited, (0..count).collect::<Vec<_>>());
			}
			for row in sweep.rows {
				assert_eq!(row.iterations, 1);
				assert_eq!(row.wall, vec![TARGET_SAMPLE_NS as f64; 5]);
				assert_eq!(row.cpu, row.wall);
			}
		}
	}
	#[test]
	fn each_probe_output_is_released_before_the_next_operation() {
		use std::{cell::Cell, rc::Rc};
		struct Live(Rc<Cell<usize>>);
		impl Drop for Live {
			fn drop(&mut self) {
				self.0.set(self.0.get() - 1);
			}
		}
		let live = Rc::new(Cell::new(0));
		let samples = sample_work(
			|| {
				assert_eq!(live.get(), 0, "prior output retained across operations");
				live.set(1);
				Live(live.clone())
			},
			|_| {},
		);
		assert_eq!(live.get(), 0);
		assert_eq!(samples.wall.len(), 5);
		assert_eq!(samples.cpu.len(), 5);
	}
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
