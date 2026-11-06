use crate::{HEADER_LEN, Header, HeaderError};
use alloc::vec::Vec;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
	OutOfMemory,
	InvalidMagic,
	Truncated,
	SizeMismatch,
	SourceHashMismatch,
	TargetHashMismatch,
	WindowTooLarge,
	CompressionFailed,
	DecompressionFailed,
	ResourceLimitExceeded,
}

impl From<difz_zstdz::Error> for Error {
	fn from(error: difz_zstdz::Error) -> Self {
		match error {
			difz_zstdz::Error::OutOfMemory => Self::OutOfMemory,
			difz_zstdz::Error::WindowTooLarge => Self::WindowTooLarge,
			difz_zstdz::Error::CompressionFailed => Self::CompressionFailed,
			difz_zstdz::Error::DecompressionFailed => Self::DecompressionFailed,
		}
	}
}
impl From<HeaderError> for Error {
	fn from(error: HeaderError) -> Self {
		match error {
			HeaderError::InvalidMagic => Self::InvalidMagic,
			HeaderError::Truncated => Self::Truncated,
		}
	}
}

pub fn window_log(source: u64, target: u64) -> Result<u32, Error> {
	Ok(difz_zstdz::window_log(source, target)?)
}

// Each registered operation defines its function and growth declaration together.
// Adding an operation forces exhaustive consumers to implement its measurement.
macro_rules! file_operations {
	($( $variant:ident => $(#[$doc:meta])* pub fn $name:ident($($arg:ident: $ty:ty),*) -> $result:ty $body:block )+) => {
		#[derive(Clone, Copy, Debug, Eq, PartialEq)]
		pub enum Operation { $( $variant ),+ }
		impl Operation {
			pub const ALL: &'static [Self] = &[$(Self::$variant),+];
			pub const fn name(self) -> &'static str { match self { $(Self::$variant => stringify!($name)),+ } }
			pub const fn expected_model(self) -> &'static str { "linear" }
		}
		$( $(#[$doc])* pub fn $name($($arg: $ty),*) -> $result $body )+
	};
}

file_operations! {
Encode =>
/// One ZDIF v4 header and one source-prefix frame; all returned memory is Rust-owned.
pub fn encode(source: &[u8], target: &[u8]) -> Result<Vec<u8>, Error> {
	window_log(source.len() as u64, target.len() as u64)?;
	let header = Header {
		source_hash: blake3::hash(source).into(),
		target_hash: blake3::hash(target).into(),
		source_len: source.len() as u64,
		target_len: target.len() as u64,
	};
	let mut output = Vec::new();
	output
		.try_reserve_exact(HEADER_LEN)
		.map_err(|_| Error::OutOfMemory)?;
	output.extend_from_slice(&header.encode());
	difz_zstdz::append_frame(source, target, &mut output)?;
	Ok(output)
}

Apply =>
/// Validate source and resource limits before allocating reconstruction output.
/// A zero limit means unlimited within the 2 GiB codec contract.
pub fn apply(source: &[u8], patch: &[u8], maximum: usize) -> Result<Vec<u8>, Error> {
	let (header, frame) = Header::decode_prefix(patch)?;
	if header.source_len != source.len() as u64 {
		return Err(Error::SizeMismatch);
	}
	if header.source_hash != *blake3::hash(source).as_bytes() {
		return Err(Error::SourceHashMismatch);
	}
	if maximum != 0 && header.target_len > maximum as u64 {
		return Err(Error::ResourceLimitExceeded);
	}
	window_log(source.len() as u64, header.target_len)?;
	let output = difz_zstdz::decode(source, frame, header.target_len as usize)?;
	if header.target_hash != *blake3::hash(&output).as_bytes() {
		return Err(Error::TargetHashMismatch);
	}
	Ok(output)
}
}
