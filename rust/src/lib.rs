#![cfg_attr(not(test), no_std)]
#![forbid(unsafe_code)]

extern crate alloc;
pub mod directory;
pub mod file;
pub mod metadata;
pub mod path_filter;
pub mod tree_patch;

const MAGIC: &[u8; 5] = b"ZDIF\x04";
const HASH_LEN: usize = 32;
const SOURCE_HASH: usize = MAGIC.len();
const TARGET_HASH: usize = SOURCE_HASH + HASH_LEN;
const SOURCE_LENGTH: usize = TARGET_HASH + HASH_LEN;
const TARGET_LENGTH: usize = SOURCE_LENGTH + core::mem::size_of::<u64>();
pub const HEADER_LEN: usize = TARGET_LENGTH + core::mem::size_of::<u64>();

/// Wire metadata only. Hashes, frame contents, window and output limits remain
/// unvalidated; parsing these lengths never authorizes allocating that output.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Header {
	pub source_hash: [u8; 32],
	pub target_hash: [u8; 32],
	pub source_len: u64,
	pub target_len: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HeaderError {
	InvalidMagic,
	Truncated,
}

impl Header {
	/// Encode every field in the fixed ZDIF v4 layout without allocation.
	pub fn encode(self) -> [u8; HEADER_LEN] {
		// Exhaustive destructuring forces serializer review when fields change.
		let Self {
			source_hash,
			target_hash,
			source_len,
			target_len,
		} = self;
		let mut bytes = [0; HEADER_LEN];
		bytes[..SOURCE_HASH].copy_from_slice(MAGIC);
		bytes[SOURCE_HASH..TARGET_HASH].copy_from_slice(&source_hash);
		bytes[TARGET_HASH..SOURCE_LENGTH].copy_from_slice(&target_hash);
		bytes[SOURCE_LENGTH..TARGET_LENGTH].copy_from_slice(&source_len.to_le_bytes());
		bytes[TARGET_LENGTH..].copy_from_slice(&target_len.to_le_bytes());
		bytes
	}

	/// Read only the fixed header and borrow the remaining frame unchanged.
	/// This is bounded work per patch; no input-proportional loop or allocation.
	pub fn decode_prefix(bytes: &[u8]) -> Result<(Self, &[u8]), HeaderError> {
		// Match the reference's precedence for short or incompatible magic.
		if bytes.get(..MAGIC.len()) != Some(&MAGIC[..]) {
			return Err(HeaderError::InvalidMagic);
		}
		let encoded = bytes.get(..HEADER_LEN).ok_or(HeaderError::Truncated)?;
		let header = Self {
			source_hash: encoded[SOURCE_HASH..TARGET_HASH]
				.try_into()
				.map_err(|_| HeaderError::Truncated)?,
			target_hash: encoded[TARGET_HASH..SOURCE_LENGTH]
				.try_into()
				.map_err(|_| HeaderError::Truncated)?,
			source_len: u64::from_le_bytes(
				encoded[SOURCE_LENGTH..TARGET_LENGTH]
					.try_into()
					.map_err(|_| HeaderError::Truncated)?,
			),
			target_len: u64::from_le_bytes(
				encoded[TARGET_LENGTH..]
					.try_into()
					.map_err(|_| HeaderError::Truncated)?,
			),
		};
		Ok((header, &bytes[HEADER_LEN..]))
	}
}

#[cfg(test)]
mod tests;
