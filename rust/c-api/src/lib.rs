#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(panic = "abort")]
compile_error!("difz C boundary requires unwind to translate Rust panics into status codes");

use std::{
	alloc::{Layout, alloc, dealloc},
	panic::{AssertUnwindSafe, catch_unwind},
	ptr,
};

pub struct Buffer {
	bytes: Vec<u8>,
}
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Status {
	InvalidData = -1,
	WrongSource = -2,
	Limit = -4,
	OutOfMemory = -5,
	Argument = -6,
	Panic = -7,
}
impl From<difz_core::file::Error> for Status {
	fn from(error: difz_core::file::Error) -> Self {
		use difz_core::file::Error;
		match error {
			Error::OutOfMemory => Self::OutOfMemory,
			Error::SizeMismatch | Error::SourceHashMismatch => Self::WrongSource,
			Error::WindowTooLarge | Error::ResourceLimitExceeded => Self::Limit,
			Error::InvalidMagic
			| Error::Truncated
			| Error::TargetHashMismatch
			| Error::CompressionFailed
			| Error::DecompressionFailed => Self::InvalidData,
		}
	}
}
fn guard(operation: impl FnOnce() -> Result<(), Status>) -> i32 {
	match catch_unwind(AssertUnwindSafe(operation)) {
		Ok(Ok(())) => 0,
		Ok(Err(status)) => status as i32,
		Err(_) => Status::Panic as i32,
	}
}
// The caller guarantees the entire nonempty region is live for this call.
unsafe fn input<'a>(data: *const u8, len: usize) -> Result<&'a [u8], Status> {
	if len > isize::MAX as usize || (len != 0 && data.is_null()) {
		return Err(Status::Argument);
	}
	if len == 0 {
		return Ok(&[]);
	}
	// Length is representable; remaining pointer validity is the C contract.
	Ok(unsafe { std::slice::from_raw_parts(data, len) })
}
fn own(bytes: Vec<u8>) -> Result<*mut Buffer, Status> {
	// This allocation retains the complete Vec, including its actual capacity.
	// Allocation failure returns an error without invoking the abort handler.
	let owner = unsafe { alloc(Layout::new::<Buffer>()) }.cast::<Buffer>();
	if owner.is_null() {
		return Err(Status::OutOfMemory);
	}
	// The allocation is fresh, correctly sized and aligned for Buffer.
	unsafe {
		owner.write(Buffer { bytes });
	}
	Ok(owner)
}
unsafe fn produce(
	out: *mut *mut Buffer,
	operation: impl FnOnce() -> Result<Vec<u8>, Status>,
) -> i32 {
	if out.is_null() {
		return Status::Argument as i32;
	}
	guard(|| {
		let owner = own(operation()?)?;
		// Publication is the final step; the caller grants a writable out slot.
		unsafe {
			out.write(owner);
		}
		Ok(())
	})
}

/// # Safety
/// Inputs and output must satisfy the contract in difz-rust.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_file_encode(
	source: *const u8,
	source_len: usize,
	target: *const u8,
	target_len: usize,
	max_bytes: usize,
	out: *mut *mut Buffer,
) -> i32 {
	// The exported contract grants borrowed input regions and a writable slot.
	unsafe {
		produce(out, || {
			let bytes =
				difz_core::file::encode(input(source, source_len)?, input(target, target_len)?)
					.map_err(Status::from)?;
			if max_bytes != 0 && bytes.len() > max_bytes {
				return Err(Status::Limit);
			}
			Ok(bytes)
		})
	}
}
/// # Safety
/// Inputs and output must satisfy the contract in difz-rust.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_file_apply(
	source: *const u8,
	source_len: usize,
	patch: *const u8,
	patch_len: usize,
	max_bytes: usize,
	out: *mut *mut Buffer,
) -> i32 {
	// Input regions are borrowed only for the duration of the guarded operation.
	unsafe {
		produce(out, || {
			difz_core::file::apply(
				input(source, source_len)?,
				input(patch, patch_len)?,
				max_bytes,
			)
			.map_err(Status::from)
		})
	}
}
/// # Safety
/// A nonnull handle must be live and returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_buffer_data(buffer: *const Buffer) -> *const u8 {
	if buffer.is_null() {
		return ptr::null();
	}
	// The live opaque owner retains this immutable buffer until free.
	let bytes = unsafe { &(*buffer).bytes };
	if bytes.is_empty() {
		ptr::null()
	} else {
		bytes.as_ptr()
	}
}
/// # Safety
/// A nonnull handle must be live and returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_buffer_len(buffer: *const Buffer) -> usize {
	if buffer.is_null() {
		return 0;
	}
	// The caller provides a live handle with an initialized Vec.
	unsafe { (*buffer).bytes.len() }
}
/// # Safety
/// A nonnull handle must be live, uniquely owned and returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_buffer_free(buffer: *mut Buffer) {
	if buffer.is_null() {
		return;
	}
	// Drop the Vec with its retained capacity, then free the exact owner layout.
	unsafe {
		ptr::drop_in_place(buffer);
		dealloc(buffer.cast(), Layout::new::<Buffer>());
	}
}
/// # Safety
/// Input and output must satisfy the contract in difz-rust.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_metadata_omit_parse(
	text: *const u8,
	len: usize,
	out: *mut u32,
) -> i32 {
	if out.is_null() {
		return Status::Argument as i32;
	}
	guard(|| {
		// Parse length-delimited bytes; a NUL is data and cannot truncate input.
		let omit = difz_core::metadata::Omit::parse(unsafe { input(text, len)? })
			.map_err(|_| Status::InvalidData)?;
		// The caller grants a writable output slot; parsing has succeeded.
		unsafe {
			out.write(omit.bits());
		}
		Ok(())
	})
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn errors_and_panics_leave_output_unchanged() {
		let sentinel = ptr::NonNull::<Buffer>::dangling().as_ptr();
		let mut output = sentinel;
		// A valid writable slot is provided; neither producer publishes a buffer.
		assert_eq!(
			unsafe { produce(&mut output, || Err(Status::OutOfMemory)) },
			Status::OutOfMemory as i32
		);
		assert_eq!(output, sentinel);
		assert_eq!(
			unsafe { produce(&mut output, || panic!("injected producer panic")) },
			Status::Panic as i32
		);
		assert_eq!(output, sentinel);
	}
	#[test]
	fn opaque_owner_retains_capacity_and_rejects_unrepresentable_regions() {
		let mut bytes = Vec::new();
		bytes.try_reserve_exact(257).unwrap();
		bytes.push(0xff);
		let pointer = bytes.as_ptr();
		let capacity = bytes.capacity();
		let owner = own(bytes).unwrap();
		// All owner accesses are within the returned owner's live lifetime.
		unsafe {
			assert_eq!((*owner).bytes.capacity(), capacity);
			assert_eq!(difz_buffer_data(owner), pointer);
			assert_eq!(difz_buffer_len(owner), 1);
			difz_buffer_free(owner);
			assert_eq!(input(ptr::null(), 0), Ok(b"".as_slice()));
			assert_eq!(input(ptr::null(), 1), Err(Status::Argument));
			assert_eq!(
				input(ptr::NonNull::<u8>::dangling().as_ptr(), usize::MAX),
				Err(Status::Argument)
			);
		}
	}
}
