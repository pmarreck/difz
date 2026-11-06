//! DIFZTREE v2 envelope integrity. Body semantics are validated separately.
use crate::metadata::Omit;

pub const HEADER_LEN: usize = 120;
const CHECKSUM_OFFSET: usize = 88;
const VERSION: u16 = 2;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	LimitExceeded,
	UnexpectedEndOfInput,
	InvalidMagic,
	UnsupportedVersion,
	PatchHashMismatch,
	ReaderTooOld,
	UnsupportedFlags,
	InvalidRule,
	InvalidOperation,
	InvalidPath,
	InvalidPayload,
	OmittedMetadataPresent,
	TrailingData,
	OutOfMemory,
	Metadata(crate::metadata::Error),
	Snapshot(crate::directory::Error),
	Filter(crate::path_filter::Error),
	File(crate::file::Error),
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EnvelopeLimits {
	pub max_patch_bytes: u64,
	pub max_entries: u32,
	pub max_rules: u32,
}
impl Default for EnvelopeLimits {
	fn default() -> Self {
		Self {
			max_patch_bytes: 16 << 30,
			max_entries: 1_000_000,
			max_rules: 4096,
		}
	}
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Header {
	pub needed_reader: u16,
	pub root_metadata: bool,
	pub omit: Omit,
	pub rule_count: u32,
	pub entry_count: u32,
	pub source_hash: [u8; 32],
	pub target_hash: [u8; 32],
}
impl Header {
	/// Encode the v2 header and checksum for this exact body, without allocation.
	/// This does not validate the body's rules, operations or metadata.
	pub fn encode(self, body: &[u8]) -> [u8; HEADER_LEN] {
		let Self {
			needed_reader,
			root_metadata,
			omit,
			rule_count,
			entry_count,
			source_hash,
			target_hash,
		} = self;
		let mut bytes = [0; HEADER_LEN];
		bytes[..8].copy_from_slice(b"DIFZTREE");
		bytes[8..10].copy_from_slice(&VERSION.to_le_bytes());
		bytes[10..12].copy_from_slice(&needed_reader.to_le_bytes());
		let flags = (omit.bits() << 1) | u32::from(root_metadata);
		bytes[12..16].copy_from_slice(&flags.to_le_bytes());
		bytes[16..20].copy_from_slice(&rule_count.to_le_bytes());
		bytes[20..24].copy_from_slice(&entry_count.to_le_bytes());
		bytes[24..56].copy_from_slice(&source_hash);
		bytes[56..88].copy_from_slice(&target_hash);
		let hash = checksum(&bytes[..CHECKSUM_OFFSET], body);
		bytes[CHECKSUM_OFFSET..].copy_from_slice(&hash);
		bytes
	}
	/// Verify v2 envelope integrity and conservative descriptor-count bounds,
	/// then borrow the body unchanged. Hashing is O(patch bytes); auxiliary
	/// memory is constant. No descriptor or output allocation is authorized by
	/// this result, and the body remains semantically unvalidated.
	pub fn decode_prefix(bytes: &[u8], limits: EnvelopeLimits) -> Result<(Self, &[u8]), Error> {
		let EnvelopeLimits {
			max_patch_bytes,
			max_entries,
			max_rules,
		} = limits;
		let length = u64::try_from(bytes.len()).map_err(|_| Error::LimitExceeded)?;
		if length > max_patch_bytes {
			return Err(Error::LimitExceeded);
		}
		let encoded: &[u8; HEADER_LEN] = bytes
			.get(..HEADER_LEN)
			.ok_or(Error::UnexpectedEndOfInput)?
			.try_into()
			.map_err(|_| Error::UnexpectedEndOfInput)?;
		if &encoded[..8] != b"DIFZTREE" {
			return Err(Error::InvalidMagic);
		}
		if u16::from_le_bytes([encoded[8], encoded[9]]) != VERSION {
			return Err(Error::UnsupportedVersion);
		}
		let body = &bytes[HEADER_LEN..];
		if checksum(&encoded[..CHECKSUM_OFFSET], body) != encoded[CHECKSUM_OFFSET..] {
			return Err(Error::PatchHashMismatch);
		}
		let needed_reader = u16::from_le_bytes([encoded[10], encoded[11]]);
		if needed_reader > VERSION {
			return Err(Error::ReaderTooOld);
		}
		let flags = word(encoded, 12);
		if flags & !0x7f != 0 {
			return Err(Error::UnsupportedFlags);
		}
		let omit = Omit::from_bits(flags >> 1).map_err(|_| Error::UnsupportedFlags)?;
		let rule_count = word(encoded, 16);
		let entry_count = word(encoded, 20);
		if rule_count > max_rules || entry_count > max_entries {
			return Err(Error::LimitExceeded);
		}
		// Divisions precede multiplication/subtraction so hostile counts cannot
		// overflow or cause an allocation even on narrower address spaces.
		let rules = usize::try_from(rule_count).map_err(|_| Error::LimitExceeded)?;
		let entries = usize::try_from(entry_count).map_err(|_| Error::LimitExceeded)?;
		if rules > body.len() / 9 || entries > (body.len() - rules * 9) / 41 {
			return Err(Error::UnexpectedEndOfInput);
		}
		Ok((
			Self {
				needed_reader,
				root_metadata: flags & 1 != 0,
				omit,
				rule_count,
				entry_count,
				source_hash: core::array::from_fn(|i| encoded[24 + i]),
				target_hash: core::array::from_fn(|i| encoded[56 + i]),
			},
			body,
		))
	}
}
fn word(bytes: &[u8; HEADER_LEN], offset: usize) -> u32 {
	u32::from_le_bytes([
		bytes[offset],
		bytes[offset + 1],
		bytes[offset + 2],
		bytes[offset + 3],
	])
}
fn checksum(prefix: &[u8], body: &[u8]) -> [u8; 32] {
	let mut hash = blake3::Hasher::new();
	hash.update(b"DIFZTREE-PATCH\x02");
	hash.update(prefix);
	hash.update(body);
	*hash.finalize().as_bytes()
}
#[cfg(test)]
#[path = "tree_patch_tests.rs"]
mod tests;

#[path = "tree_patch_decode.rs"]
mod decode;
pub use decode::{DecodedEntry, Limits, Operation, ParsedPatch};
#[path = "tree_patch_encode.rs"]
mod encode;
pub use encode::{CreateOptions, create};
