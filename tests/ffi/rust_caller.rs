use std::ffi::{c_char, c_int, CString};
use std::ptr::{self, NonNull};

#[link(name = "difz", kind = "static")]
unsafe extern "C" {
	fn difz_diff(
		a: *const u8,
		a_len: usize,
		b: *const u8,
		b_len: usize,
		out: *mut *mut u8,
		len: *mut usize,
	) -> c_int;
	fn difz_patch(
		a: *const u8,
		a_len: usize,
		patch: *const u8,
		patch_len: usize,
		out: *mut *mut u8,
		len: *mut usize,
	) -> c_int;
	fn difz_diff_limited(
		a: *const u8,
		a_len: usize,
		b: *const u8,
		b_len: usize,
		limit: usize,
		out: *mut *mut u8,
		len: *mut usize,
	) -> c_int;
	fn difz_patch_limited(
		a: *const u8,
		a_len: usize,
		patch: *const u8,
		patch_len: usize,
		limit: usize,
		out: *mut *mut u8,
		len: *mut usize,
	) -> c_int;
	fn difz_parse_metadata_omit(text: *const c_char, mask: *mut u32) -> c_int;
	fn difz_directory_diff(
		source: *const c_char,
		target: *const c_char,
		rules: *const std::ffi::c_void,
		count: usize,
		omit: u32,
		out: *mut *mut u8,
		len: *mut usize,
	) -> c_int;
	fn difz_directory_patch(
		source: *const c_char,
		patch: *const u8,
		len: usize,
		output: *const c_char,
		compromises: *mut u32,
	) -> c_int;
	fn difz_free(data: *mut u8, len: usize);
}

// The foreign allocator retains ownership until difz_free, never Rust's Vec.
struct ForeignBuffer {
	ptr: NonNull<u8>,
	len: usize,
}

impl ForeignBuffer {
	unsafe fn returned(ptr: *mut u8, len: usize) -> Self {
		Self {
			ptr: NonNull::new(ptr).expect("successful FFI call returned null"),
			len,
		}
	}
	fn bytes(&self) -> &[u8] {
		// The successful FFI call granted len readable bytes for this lifetime.
		unsafe { std::slice::from_raw_parts(self.ptr.as_ptr(), self.len) }
	}
}

impl Drop for ForeignBuffer {
	fn drop(&mut self) {
		// This pointer and length are the exact pair returned by difz.
		unsafe { difz_free(self.ptr.as_ptr(), self.len) }
	}
}

fn round_trip(source: &[u8], target: &[u8]) {
	let (mut patch_ptr, mut patch_len) = (ptr::null_mut(), 0);
	assert_eq!(
		unsafe {
			difz_diff(
				source.as_ptr(),
				source.len(),
				target.as_ptr(),
				target.len(),
				&mut patch_ptr,
				&mut patch_len,
			)
		},
		0
	);
	let patch = unsafe { ForeignBuffer::returned(patch_ptr, patch_len) };
	assert_eq!(&patch.bytes()[..5], b"ZDIF\x04");
	let (mut output_ptr, mut output_len) = (ptr::null_mut(), 0);
	assert_eq!(
		unsafe {
			difz_patch(
				source.as_ptr(),
				source.len(),
				patch.ptr.as_ptr(),
				patch.len,
				&mut output_ptr,
				&mut output_len,
			)
		},
		0
	);
	let output = unsafe { ForeignBuffer::returned(output_ptr, output_len) };
	assert_eq!(output.bytes(), target);

	let sentinel = NonNull::<u8>::dangling().as_ptr();
	let (mut rejected, mut rejected_len) = (sentinel, 77);
	assert_eq!(
		unsafe {
			difz_diff_limited(
				source.as_ptr(),
				source.len(),
				target.as_ptr(),
				target.len(),
				1,
				&mut rejected,
				&mut rejected_len,
			)
		},
		-4
	);
	assert_eq!((rejected, rejected_len), (sentinel, 77));
	if target.len() > 1 {
		assert_eq!(
			unsafe {
				difz_patch_limited(
					source.as_ptr(),
					source.len(),
					patch.ptr.as_ptr(),
					patch.len,
					target.len() - 1,
					&mut rejected,
					&mut rejected_len,
				)
			},
			-4
		);
		assert_eq!((rejected, rejected_len), (sentinel, 77));
	}
	let mut wrong = source.to_vec();
	if wrong.is_empty() {
		wrong.push(1);
	} else {
		wrong[0] ^= 1;
	}
	assert_eq!(
		unsafe {
			difz_patch(
				wrong.as_ptr(),
				wrong.len(),
				patch.ptr.as_ptr(),
				patch.len,
				&mut rejected,
				&mut rejected_len,
			)
		},
		-1
	);
	assert_eq!((rejected, rejected_len), (sentinel, 77));
}

fn omission_masks() {
	let names = ["xattr", "acl", "timestamps", "finder", "sparse", "hardlink"];
	for bits in 0_u32..64 {
		let selected: Vec<_> = names
			.iter()
			.enumerate()
			.filter_map(|(i, name)| (bits & (1 << i) != 0).then_some(*name))
			.collect();
		let text = CString::new(selected.join(",")).unwrap();
		let mut result = 99;
		assert_eq!(
			unsafe { difz_parse_metadata_omit(text.as_ptr(), &mut result) },
			0
		);
		assert_eq!(result, bits);
	}
	for invalid in ["unknown", "acl,acl", "acl,", ",xattr", "acl,,finder"] {
		let text = CString::new(invalid).unwrap();
		let mut result = 99;
		assert_eq!(
			unsafe { difz_parse_metadata_omit(text.as_ptr(), &mut result) },
			-1
		);
		assert_eq!(result, 99);
	}
}

struct Fixture(std::path::PathBuf);
impl Drop for Fixture {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).expect("clean owned fixture");
	}
}

fn directory_round_trip() {
	let root = std::env::temp_dir().join(format!("difz-rust-ffi-{}", std::process::id()));
	std::fs::create_dir(&root).unwrap();
	let fixture = Fixture(root);
	let source = fixture.0.join("source");
	let target = fixture.0.join("target");
	let output = fixture.0.join("output");
	std::fs::create_dir(&source).unwrap();
	std::fs::create_dir(&target).unwrap();
	std::fs::write(source.join("data"), b"old\0\xff").unwrap();
	std::fs::write(target.join("data"), b"new\0\x80").unwrap();
	let source_c = CString::new(source.to_str().unwrap()).unwrap();
	let target_c = CString::new(target.to_str().unwrap()).unwrap();
	let output_c = CString::new(output.to_str().unwrap()).unwrap();
	let (mut patch_ptr, mut patch_len) = (ptr::null_mut(), 0);
	assert_eq!(
		unsafe {
			difz_directory_diff(
				source_c.as_ptr(),
				target_c.as_ptr(),
				ptr::null(),
				0,
				63,
				&mut patch_ptr,
				&mut patch_len,
			)
		},
		0
	);
	let patch = unsafe { ForeignBuffer::returned(patch_ptr, patch_len) };
	let mut compromises = u32::MAX;
	assert_eq!(
		unsafe {
			difz_directory_patch(
				source_c.as_ptr(),
				patch.ptr.as_ptr(),
				patch.len,
				output_c.as_ptr(),
				&mut compromises,
			)
		},
		0
	);
	assert_eq!(compromises, 0);
	assert_eq!(std::fs::read(output.join("data")).unwrap(), b"new\0\x80");
	assert_eq!(std::fs::read(source.join("data")).unwrap(), b"old\0\xff");
}

fn main() {
	let all: Vec<u8> = (0..=255).collect();
	let reversed: Vec<u8> = all.iter().rev().copied().collect();
	for (source, target) in [
		(&[][..], &[][..]),
		(&[][..], &all),
		(&all, &[][..]),
		(&all, &reversed),
		(&b"alpha\0beta\xff"[..], &b"alpha\0BETA\x80\0"[..]),
	] {
		round_trip(source, target);
	}
	omission_masks();
	directory_round_trip();
}
