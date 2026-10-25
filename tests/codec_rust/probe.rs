//! Optimized QA probe. File I/O stays outside the codec timing interval.
#![deny(unsafe_op_in_unsafe_fn)]

use difz_rust_codec_check::codecs;
use std::ffi::{c_void, OsString};
use std::ptr::NonNull;
use std::time::Instant;
mod parallel;

#[allow(
	non_camel_case_types,
	non_snake_case,
	non_upper_case_globals,
	dead_code
)]
mod native {
	include!(env!("DIFZ_ZSTD_BINDINGS"));
	#[link(name = "zstd", kind = "static")]
	unsafe extern "C" {}
}

struct Encoder(NonNull<native::ZSTD_CCtx>);
impl Drop for Encoder {
	fn drop(&mut self) {
		// This handle is created once and is never shared or freed elsewhere.
		unsafe { native::ZSTD_freeCCtx(self.0.as_ptr()) };
	}
}
struct Decoder(NonNull<native::ZSTD_DCtx>);
impl Drop for Decoder {
	fn drop(&mut self) {
		// The source and input buffers outlive this synchronous context.
		unsafe { native::ZSTD_freeDCtx(self.0.as_ptr()) };
	}
}
fn checked(result: usize) -> usize {
	// isError only inspects the numeric status returned by the same library.
	assert_eq!(
		unsafe { native::ZSTD_isError(result) },
		0,
		"zstd status {result}"
	);
	result
}
fn process_cpu_ns() -> u128 {
	let mut stamp = std::mem::MaybeUninit::<native::timespec>::uninit();
	// Bindings use this host's time.h; success initializes both timespec fields.
	assert_eq!(
		unsafe { native::clock_gettime(native::CLOCK_PROCESS_CPUTIME_ID as _, stamp.as_mut_ptr()) },
		0
	);
	let stamp = unsafe { stamp.assume_init() };
	let seconds = u128::try_from(stamp.tv_sec).unwrap();
	let nanos = u128::try_from(stamp.tv_nsec).unwrap();
	assert!(nanos < 1_000_000_000);
	seconds * 1_000_000_000 + nanos
}
fn native_encode(source: &[u8], target: &[u8]) -> Vec<u8> {
	// The returned context owns its state and is freed by Encoder.
	let context =
		Encoder(NonNull::new(unsafe { native::ZSTD_createCCtx() }).expect("zstd context"));
	let span = source.len().max(target.len());
	let raw_log = usize::BITS - span.leading_zeros();
	let window = raw_log.clamp(10, 31);
	// This by-value C struct comes from bindings generated from the pinned header.
	let parameters = unsafe { native::ZSTD_getCParams(9, target.len() as u64, source.len()) };
	let cycle_log = parameters.chainLog - u32::from(parameters.strategy >= native::ZSTD_btlazy2);
	for (parameter, value) in [
		(native::ZSTD_c_compressionLevel, 9),
		(native::ZSTD_c_nbWorkers, 0),
		(native::ZSTD_c_windowLog, window as i32),
		(
			native::ZSTD_c_enableLongDistanceMatching,
			i32::from(raw_log > cycle_log),
		),
		(native::ZSTD_c_chainLog, parameters.chainLog as i32),
		(native::ZSTD_c_hashLog, parameters.hashLog as i32),
		(native::ZSTD_c_searchLog, parameters.searchLog as i32),
		(native::ZSTD_c_minMatch, parameters.minMatch as i32),
		(native::ZSTD_c_targetLength, parameters.targetLength as i32),
		(native::ZSTD_c_strategy, parameters.strategy as i32),
	] {
		// The live handle and enum constants are from the same pinned C API.
		checked(unsafe { native::ZSTD_CCtx_setParameter(context.0.as_ptr(), parameter, value) });
	}
	if !source.is_empty() {
		// The immutable prefix stays alive until compression and context teardown finish.
		checked(unsafe {
			native::ZSTD_CCtx_refPrefix(context.0.as_ptr(), source.as_ptr().cast(), source.len())
		});
	}
	let capacity = checked(unsafe { native::ZSTD_compressBound(target.len()) });
	let mut output = Vec::<u8>::with_capacity(capacity);
	let input = if target.is_empty() {
		std::ptr::null()
	} else {
		target.as_ptr().cast::<c_void>()
	};
	// C may write only within this allocation. No initialized Rust bytes are read yet.
	let written = checked(unsafe {
		native::ZSTD_compress2(
			context.0.as_ptr(),
			output.as_mut_ptr().cast(),
			capacity,
			input,
			target.len(),
		)
	});
	assert!(written <= capacity);
	// Successful compression initialized exactly the reported prefix of the buffer.
	unsafe { output.set_len(written) };
	output
}
fn decoder() -> Decoder {
	let context =
		Decoder(NonNull::new(unsafe { native::ZSTD_createDCtx() }).expect("zstd context"));
	checked(unsafe { native::ZSTD_DCtx_setMaxWindowSize(context.0.as_ptr(), 1 << 31) });
	context
}
fn native_decode_into(context: &Decoder, source: &[u8], frame: &[u8], output: &mut [u8]) {
	if !source.is_empty() {
		// Prefix storage remains immutable and live through this synchronous decode.
		checked(unsafe {
			native::ZSTD_DCtx_refPrefix(context.0.as_ptr(), source.as_ptr().cast(), source.len())
		});
	}
	let destination = if output.is_empty() {
		std::ptr::null_mut()
	} else {
		output.as_mut_ptr().cast::<c_void>()
	};
	// Input/output do not overlap; the supplied capacity is the actual slice length.
	let written = checked(unsafe {
		native::ZSTD_decompressDCtx(
			context.0.as_ptr(),
			destination,
			output.len(),
			frame.as_ptr().cast(),
			frame.len(),
		)
	});
	assert_eq!(written, output.len());
}
fn native_decode(source: &[u8], frame: &[u8], expected: usize) -> Vec<u8> {
	let context = decoder();
	let mut output = vec![0; expected];
	native_decode_into(&context, source, frame, &mut output);
	output
}
fn run(arguments: &[OsString]) -> Result<(), String> {
	if arguments.len() < 6 {
		return Err("usage: difz-codec-probe encode|decode CODEC SOURCE INPUT OUTPUT [OUTPUT_BYTES]; c-chunks encode appends CHUNK_BYTES WORKERS, decode appends OUTPUT_BYTES WORKERS".into());
	}
	let operation = arguments[1].to_str().ok_or("invalid operation")?;
	let codec = arguments[2].to_str().ok_or("invalid codec")?;
	if !matches!(
		codec,
		"c" | "c-chunks" | "rusty" | "structured" | "structured-owned"
	) {
		return Err("unknown codec".into());
	}
	if !matches!(operation, "encode" | "decode") {
		return Err("unknown operation".into());
	}
	let expected_arguments = if codec == "c-chunks" {
		8
	} else if operation == "encode" {
		6
	} else {
		7
	};
	if arguments.len() != expected_arguments {
		return Err("incorrect argument count".into());
	}
	let source = std::fs::read(&arguments[3]).map_err(|error| error.to_string())?;
	let input = std::fs::read(&arguments[4]).map_err(|error| error.to_string())?;
	let expected = if operation == "decode" {
		arguments[6]
			.to_str()
			.ok_or("invalid output length")?
			.parse::<usize>()
			.map_err(|error| error.to_string())?
	} else {
		0
	};
	let workers = if codec == "c-chunks" {
		arguments[7]
			.to_str()
			.ok_or("invalid workers")?
			.parse::<usize>()
			.map_err(|error| error.to_string())?
	} else {
		1
	};
	if !(1..=64).contains(&workers) {
		return Err("workers must be in 1..=64".into());
	}
	let chunk_bytes = if codec == "c-chunks" && operation == "encode" {
		arguments[6]
			.to_str()
			.ok_or("invalid chunk size")?
			.parse::<usize>()
			.map_err(|error| error.to_string())?
	} else {
		1
	};
	if chunk_bytes == 0 {
		return Err("chunk size must be positive".into());
	}
	let cpu_start = process_cpu_ns();
	let start = Instant::now();
	let mut frames = 1;
	let mut workers_used = 1;
	let output = match (operation, codec) {
		("encode", "c") => native_encode(&source, &input),
		("encode", "c-chunks") => {
			let result = parallel::encode(&source, &input, chunk_bytes, workers);
			frames = result.1;
			workers_used = result.2;
			result.0
		}
		("encode", "rusty") => codecs::rust_frame(&source, &input, None),
		("encode", "structured") => codecs::structured_frame(&source, &input, None),
		("encode", "structured-owned") => codecs::structured_frame_owned(source, &input, None),
		("decode", "c") => native_decode(&source, &input, expected),
		("decode", "c-chunks") => {
			let result = parallel::decode(&source, &input, expected, workers);
			frames = result.1;
			workers_used = result.2;
			result.0
		}
		("decode", "rusty") => codecs::rust_decode(&input, &source, expected),
		("decode", "structured") => codecs::structured_decode(&input, &source, expected),
		("decode", "structured-owned") => codecs::structured_decode_owned(&input, source, expected),
		_ => unreachable!(),
	};
	let wall_ns = start.elapsed().as_nanos();
	let cpu_ns = process_cpu_ns()
		.checked_sub(cpu_start)
		.expect("monotonic process CPU clock");
	std::fs::write(&arguments[5], &output).map_err(|error| error.to_string())?;
	println!(
		"{{\"wall_ns\":{wall_ns},\"cpu_ns\":{cpu_ns},\"output_bytes\":{},\"frames\":{frames},\"workers_used\":{workers_used}}}",
		output.len()
	);
	Ok(())
}
fn main() {
	if let Err(error) = run(&std::env::args_os().collect::<Vec<_>>()) {
		eprintln!("{error}");
		std::process::exit(2);
	}
}
