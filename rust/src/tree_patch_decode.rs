use super::{EnvelopeLimits, Error, Header};
use crate::{
	directory::structure,
	metadata::{CanonicalMetadata, Family, Metadata, Omit, Times},
	path_filter::{Action, Filter, Rule},
};
use alloc::vec::Vec;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
	pub envelope: EnvelopeLimits,
	pub max_path_bytes: u32,
	pub max_pattern_bytes: u32,
	pub max_symlink_bytes: u64,
	pub max_payload_bytes: u64,
}
impl Default for Limits {
	fn default() -> Self {
		Self {
			envelope: EnvelopeLimits::default(),
			max_path_bytes: 4096,
			max_pattern_bytes: 4096,
			max_symlink_bytes: 65_536,
			max_payload_bytes: 8 << 30,
		}
	}
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Operation {
	Directory = 1,
	Symlink = 2,
	FileCopy = 3,
	FileRaw = 4,
	FileDelta = 5,
	FileHardlink = 6,
}
impl TryFrom<u8> for Operation {
	type Error = Error;
	fn try_from(tag: u8) -> Result<Self, Error> {
		match tag {
			1 => Ok(Self::Directory),
			2 => Ok(Self::Symlink),
			3 => Ok(Self::FileCopy),
			4 => Ok(Self::FileRaw),
			5 => Ok(Self::FileDelta),
			6 => Ok(Self::FileHardlink),
			_ => Err(Error::InvalidOperation),
		}
	}
}
#[derive(Debug)]
pub struct DecodedEntry<'a> {
	pub(super) path: &'a [u8],
	pub(super) mode: u16,
	pub(super) operation: Operation,
	pub(super) payload: &'a [u8],
	pub(super) metadata: CanonicalMetadata<'a>,
}
impl<'a> DecodedEntry<'a> {
	pub fn path(&self) -> &'a [u8] {
		self.path
	}
	pub fn mode_bits(&self) -> u16 {
		self.mode
	}
	pub fn operation(&self) -> Operation {
		self.operation
	}
	/// Deltas remain opaque until application; copy/directory payloads are empty.
	pub fn payload(&self) -> &'a [u8] {
		self.payload
	}
	pub fn metadata(&self) -> &CanonicalMetadata<'a> {
		&self.metadata
	}
}
impl structure::View for DecodedEntry<'_> {
	fn structure(&self) -> structure::Record<'_> {
		let Self {
			path,
			mode,
			operation,
			payload,
			metadata: _,
		} = self;
		let kind = match operation {
			Operation::Directory => structure::Kind::Directory,
			Operation::Symlink => structure::Kind::Symlink,
			Operation::FileCopy
			| Operation::FileRaw
			| Operation::FileDelta
			| Operation::FileHardlink => structure::Kind::File,
		};
		structure::Record {
			path,
			mode: *mode,
			kind,
			data: payload,
		}
	}
}
/// Integrity, body grammar, canonical metadata and hierarchy are checked.
/// Expanded file relations, delta frames and source/target identities are
/// application checks. Byte fields borrow the patch; descriptor storage owns.
#[derive(Debug)]
pub struct ParsedPatch<'a> {
	pub(super) header: Header,
	pub(super) rules: Vec<Rule<'a>>,
	pub(super) entries: Vec<DecodedEntry<'a>>,
	pub(super) root: CanonicalMetadata<'a>,
}
impl<'a> ParsedPatch<'a> {
	pub fn header(&self) -> &Header {
		&self.header
	}
	pub fn rules(&self) -> &[Rule<'a>] {
		&self.rules
	}
	pub fn entries(&self) -> &[DecodedEntry<'a>] {
		&self.entries
	}
	pub fn root_metadata(&self) -> &CanonicalMetadata<'a> {
		&self.root
	}
	/// Expected O(patch bytes + entry-count log entry-count + pattern bytes).
	/// Only checked descriptor arrays allocate; payloads and names stay borrowed.
	pub fn decode(bytes: &'a [u8], limits: Limits) -> Result<Self, Error> {
		let Limits {
			envelope,
			max_path_bytes,
			max_pattern_bytes,
			max_symlink_bytes,
			max_payload_bytes,
		} = limits;
		let (header, body) = Header::decode_prefix(bytes, envelope)?;
		let mut reader = Reader {
			bytes: body,
			position: 0,
		};
		let mut rules = Vec::new();
		rules
			.try_reserve_exact(header.rule_count as usize)
			.map_err(|_| Error::OutOfMemory)?;
		for _ in 0..header.rule_count {
			let action = match reader.byte()? {
				1 => Action::Include,
				2 => Action::Exclude,
				_ => return Err(Error::InvalidRule),
			};
			if reader.byte()? != 0 || reader.u16()? != 0 {
				return Err(Error::InvalidRule);
			}
			let length = reader.length32(u64::from(max_pattern_bytes))?;
			if length == 0 {
				return Err(Error::InvalidRule);
			}
			let pattern = core::str::from_utf8(reader.take(length)?)
				.map_err(|_| Error::Snapshot(crate::directory::Error::InvalidUtf8))?;
			rules.push(Rule { action, pattern });
		}
		if !rules.is_empty() {
			let _ = Filter::compile(&rules).map_err(Error::Filter)?;
		}
		let mut entries = Vec::new();
		entries
			.try_reserve_exact(header.entry_count as usize)
			.map_err(|_| Error::OutOfMemory)?;
		for _ in 0..header.entry_count {
			let operation = Operation::try_from(reader.byte()?)?;
			if reader.byte()? != 0 {
				return Err(Error::UnsupportedFlags);
			}
			let mode = reader.u16()?;
			let path_length = reader.length32(u64::from(max_path_bytes))?;
			if path_length == 0 {
				return Err(Error::InvalidPath);
			}
			let payload_length = Reader::length(reader.u64()?, max_payload_bytes)?;
			let path = reader.take(path_length)?;
			let payload = reader.take(payload_length)?;
			let metadata_length = reader.length32(max_payload_bytes)?;
			let metadata = CanonicalMetadata::decode(reader.take(metadata_length)?)
				.map_err(Error::Metadata)?;
			if has_omitted(metadata.metadata(), header.omit) {
				return Err(Error::OmittedMetadataPresent);
			}
			match operation {
				Operation::Directory | Operation::FileCopy => {
					if !payload.is_empty() {
						return Err(Error::InvalidPayload);
					}
				}
				Operation::Symlink => {
					if payload.len() as u64 > max_symlink_bytes {
						return Err(Error::LimitExceeded);
					}
				}
				Operation::FileHardlink => {
					if metadata.metadata().hardlink_to.as_deref() != Some(payload) {
						return Err(Error::Snapshot(
							crate::directory::Error::InvalidHardlinkRelation,
						));
					}
				}
				Operation::FileRaw | Operation::FileDelta => {}
			}
			if metadata.metadata().hardlink_to.is_some() && operation != Operation::FileHardlink {
				return Err(Error::Snapshot(
					crate::directory::Error::InvalidHardlinkRelation,
				));
			}
			entries.push(DecodedEntry {
				path,
				mode,
				operation,
				payload,
				metadata,
			});
		}
		let root = if header.root_metadata {
			let length = reader.length32(max_payload_bytes)?;
			let root = CanonicalMetadata::decode(reader.take(length)?).map_err(Error::Metadata)?;
			if has_omitted(root.metadata(), header.omit) {
				return Err(Error::OmittedMetadataPresent);
			}
			if root.metadata().is_empty() {
				return Err(Error::Metadata(crate::metadata::Error::BadMetadata));
			}
			if !root.metadata().holes.is_empty() {
				return Err(Error::Snapshot(
					crate::directory::Error::InvalidSparseExtent,
				));
			}
			if root.metadata().hardlink_to.is_some() {
				return Err(Error::Snapshot(
					crate::directory::Error::InvalidHardlinkRelation,
				));
			}
			root
		} else {
			CanonicalMetadata::default()
		};
		if reader.position != body.len() {
			return Err(Error::TrailingData);
		}
		structure::validate(&entries).map_err(Error::Snapshot)?;
		Ok(Self {
			header,
			rules,
			entries,
			root,
		})
	}
}

struct Reader<'a> {
	bytes: &'a [u8],
	position: usize,
}
impl<'a> Reader<'a> {
	fn take(&mut self, length: usize) -> Result<&'a [u8], Error> {
		let end = self
			.position
			.checked_add(length)
			.ok_or(Error::UnexpectedEndOfInput)?;
		let bytes = self
			.bytes
			.get(self.position..end)
			.ok_or(Error::UnexpectedEndOfInput)?;
		self.position = end;
		Ok(bytes)
	}
	fn array<const N: usize>(&mut self) -> Result<[u8; N], Error> {
		self.take(N)?
			.try_into()
			.map_err(|_| Error::UnexpectedEndOfInput)
	}
	fn byte(&mut self) -> Result<u8, Error> {
		Ok(self.take(1)?[0])
	}
	fn u16(&mut self) -> Result<u16, Error> {
		Ok(u16::from_le_bytes(self.array()?))
	}
	fn u32(&mut self) -> Result<u32, Error> {
		Ok(u32::from_le_bytes(self.array()?))
	}
	fn u64(&mut self) -> Result<u64, Error> {
		Ok(u64::from_le_bytes(self.array()?))
	}
	fn length(length: u64, limit: u64) -> Result<usize, Error> {
		if length > limit {
			return Err(Error::LimitExceeded);
		}
		usize::try_from(length).map_err(|_| Error::LimitExceeded)
	}
	fn length32(&mut self, limit: u64) -> Result<usize, Error> {
		Self::length(u64::from(self.u32()?), limit)
	}
}
fn has_omitted(metadata: &Metadata<'_>, omit: Omit) -> bool {
	let Metadata {
		xattrs,
		aces,
		native_acl,
		times,
		finder_flags,
		finder_info,
		holes,
		hardlink_to,
	} = metadata;
	let Times {
		mtime,
		atime,
		btime,
	} = times;
	Family::ALL.iter().any(|family| {
		omit.contains(*family)
			&& match family {
				Family::Xattr => !xattrs.is_empty(),
				Family::Acl => !aces.is_empty() || native_acl.is_some(),
				Family::Timestamps => mtime.is_some() || atime.is_some() || btime.is_some(),
				Family::Finder => *finder_flags != 0 || finder_info.is_some(),
				Family::Sparse => !holes.is_empty(),
				Family::Hardlink => hardlink_to.is_some(),
			}
	})
}

#[cfg(test)]
#[path = "tree_patch_decode_tests.rs"]
mod tests;
