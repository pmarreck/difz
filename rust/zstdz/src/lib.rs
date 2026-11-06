#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

extern crate alloc;

use alloc::vec::Vec;
use core::{
	ffi::c_void,
	ptr::{self, NonNull},
};

#[allow(
	non_camel_case_types,
	non_upper_case_globals,
	non_snake_case,
	dead_code
)]
mod native {
	include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

pub const MAX_INPUT_LEN: u64 = 1 << 31;
const _: () = assert!(native::ZSTD_WINDOWLOG_MIN == 10 && native::DIFZ_ZSTD_WINDOWLOG_MAX == 31);

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum Error {
	OutOfMemory,
	WindowTooLarge,
	CompressionFailed,
	DecompressionFailed,
}

pub fn window_log(source: u64, target: u64) -> Result<u32, Error> {
	if source > MAX_INPUT_LEN || target > MAX_INPUT_LEN {
		return Err(Error::WindowTooLarge);
	}
	Ok((64 - source.max(target).leading_zeros()).clamp(10, 31))
}

fn checked(status: usize, error: Error) -> Result<usize, Error> {
	// The status comes from this same pinned library; no pointer is dereferenced.
	if unsafe { native::ZSTD_isError(status) } != 0 {
		Err(error)
	} else {
		Ok(status)
	}
}

struct Encoder(NonNull<native::ZSTD_CCtx>);
impl Drop for Encoder {
	fn drop(&mut self) {
		// This operation uniquely owns the context and frees it exactly once.
		unsafe { native::ZSTD_freeCCtx(self.0.as_ptr()) };
	}
}
struct Decoder(NonNull<native::ZSTD_DCtx>);
impl Drop for Decoder {
	fn drop(&mut self) {
		// No context or borrowed prefix escapes this synchronous operation.
		unsafe { native::ZSTD_freeDCtx(self.0.as_ptr()) };
	}
}

fn input(bytes: &[u8]) -> *const c_void {
	if bytes.is_empty() {
		ptr::null()
	} else {
		bytes.as_ptr().cast()
	}
}

/// Append one level-9, zero-worker frame. Inputs remain borrowed through context
/// teardown. On failure the Vec's initialized length and existing bytes stay intact.
pub fn append_frame(source: &[u8], target: &[u8], output: &mut Vec<u8>) -> Result<(), Error> {
	let window = window_log(source.len() as u64, target.len() as u64)?;
	// The native allocator returns either a fresh owned handle or null.
	let context =
		Encoder(NonNull::new(unsafe { native::ZSTD_createCCtx() }).ok_or(Error::OutOfMemory)?);
	// Bindings and archive come from the same pinned header/source derivation.
	let parameters = unsafe { native::ZSTD_getCParams(9, target.len() as u64, source.len()) };
	let raw_log = usize::BITS - source.len().max(target.len()).leading_zeros();
	let cycle_log = parameters
		.chainLog
		.checked_sub(u32::from(parameters.strategy >= native::ZSTD_btlazy2))
		.ok_or(Error::CompressionFailed)?;
	for (parameter, value) in [
		(native::ZSTD_c_compressionLevel, 9),
		(native::ZSTD_c_nbWorkers, 0),
		(
			native::ZSTD_c_enableLongDistanceMatching,
			i32::from(raw_log > cycle_log),
		),
		(native::ZSTD_c_windowLog, window as i32),
		(native::ZSTD_c_chainLog, parameters.chainLog as i32),
		(native::ZSTD_c_hashLog, parameters.hashLog as i32),
		(native::ZSTD_c_searchLog, parameters.searchLog as i32),
		(native::ZSTD_c_minMatch, parameters.minMatch as i32),
		(native::ZSTD_c_targetLength, parameters.targetLength as i32),
		(native::ZSTD_c_strategy, parameters.strategy as i32),
	] {
		// The context is live and exclusive; parameters are generated C constants.
		checked(
			unsafe { native::ZSTD_CCtx_setParameter(context.0.as_ptr(), parameter, value) },
			Error::CompressionFailed,
		)?;
	}
	if !source.is_empty() {
		// The immutable prefix outlives compression and context destruction.
		checked(
			unsafe { native::ZSTD_CCtx_refPrefix(context.0.as_ptr(), input(source), source.len()) },
			Error::CompressionFailed,
		)?;
	}
	// Length was bounded before calling the native size calculation.
	let bound = checked(
		unsafe { native::ZSTD_compressBound(target.len()) },
		Error::CompressionFailed,
	)?;
	let start = output.len();
	output
		.try_reserve_exact(bound)
		.map_err(|_| Error::OutOfMemory)?;
	// Spare capacity covers [start, start+bound), is exclusive, and does not
	// overlap either borrowed input. C initializes only its returned byte count.
	let written = checked(
		unsafe {
			native::ZSTD_compress2(
				context.0.as_ptr(),
				output.as_mut_ptr().add(start).cast(),
				bound,
				input(target),
				target.len(),
			)
		},
		Error::CompressionFailed,
	)?;
	if written > bound {
		return Err(Error::CompressionFailed);
	}
	// Existing bytes and exactly `written` new bytes are initialized on success.
	unsafe {
		output.set_len(start + written);
	}
	Ok(())
}

/// Decode into Rust-owned capacity without publishing uninitialized bytes.
/// The exact output capacity bounds writes even for hostile compressed input.
pub fn decode(source: &[u8], frame: &[u8], expected: usize) -> Result<Vec<u8>, Error> {
	window_log(source.len() as u64, expected as u64)?;
	let mut output = Vec::<u8>::new();
	output
		.try_reserve_exact(expected)
		.map_err(|_| Error::OutOfMemory)?;
	// A fresh context belongs to this operation only.
	let context =
		Decoder(NonNull::new(unsafe { native::ZSTD_createDCtx() }).ok_or(Error::OutOfMemory)?);
	// The context is live; the limit matches the validated file contract.
	checked(
		unsafe { native::ZSTD_DCtx_setMaxWindowSize(context.0.as_ptr(), MAX_INPUT_LEN as usize) },
		Error::DecompressionFailed,
	)?;
	if !source.is_empty() {
		// Borrowed immutable prefix remains alive through decode and context drop.
		checked(
			unsafe { native::ZSTD_DCtx_refPrefix(context.0.as_ptr(), input(source), source.len()) },
			Error::DecompressionFailed,
		)?;
	}
	let destination = if expected == 0 {
		ptr::null_mut()
	} else {
		output.as_mut_ptr().cast()
	};
	// C can write at most the exact advertised target length. Input and output
	// do not overlap. Failed/partial output retains a zero initialized Vec length.
	let written = checked(
		unsafe {
			native::ZSTD_decompressDCtx(
				context.0.as_ptr(),
				destination,
				expected,
				input(frame),
				frame.len(),
			)
		},
		Error::DecompressionFailed,
	)?;
	if written != expected {
		return Err(Error::DecompressionFailed);
	}
	// A successful exact-size decode initialized every published byte.
	unsafe {
		output.set_len(written);
	}
	Ok(output)
}
