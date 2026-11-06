//! Linux POSIX ACL records and their portable DIFZACL container, without I/O.
use crate::metadata::{Ace, AceTag, CanonicalMetadata, Permissions};
use alloc::{borrow::Cow, vec::Vec};
const MAGIC: &[u8; 8] = b"DIFZACL\x01";
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	InvalidAcl,
	OutOfMemory,
	UnrepresentableAcl,
}

/// Encode canonical portable ACEs in kernel tag/ID order. Expected O(n log n)
/// comparisons and linear name/byte work; allocations are fallible.
pub fn encode_portable(metadata: &CanonicalMetadata<'_>) -> Result<Vec<u8>, Error> {
	let aces = &metadata.metadata().aces;
	if aces.is_empty() {
		return Ok(Vec::new());
	}
	let mut entries = Vec::new();
	entries
		.try_reserve_exact(aces.len())
		.map_err(|_| Error::OutOfMemory)?;
	for Ace {
		tag,
		permissions,
		name,
	} in aces
	{
		let (tag, id) = match tag {
			AceTag::Owner => (1u16, u32::MAX),
			AceTag::Group => (4, u32::MAX),
			AceTag::Everyone => (32, u32::MAX),
			AceTag::Mask => (16, u32::MAX),
			AceTag::NamedUser => (2, principal(name)?),
			AceTag::NamedGroup => (8, principal(name)?),
		};
		let perm = (u16::from(permissions.contains(Permissions::READ)) << 2)
			| (u16::from(permissions.contains(Permissions::WRITE)) << 1)
			| u16::from(permissions.contains(Permissions::EXECUTE));
		entries.push((tag, id, perm));
	}
	entries.sort_unstable_by_key(|&(tag, id, _)| (tag, id));
	let length = entries
		.len()
		.checked_mul(8)
		.and_then(|n| n.checked_add(4))
		.ok_or(Error::InvalidAcl)?;
	let mut bytes = Vec::new();
	bytes
		.try_reserve_exact(length)
		.map_err(|_| Error::OutOfMemory)?;
	bytes.extend_from_slice(&2u32.to_le_bytes());
	for (tag, id, perm) in entries {
		bytes.extend_from_slice(&tag.to_le_bytes());
		bytes.extend_from_slice(&perm.to_le_bytes());
		bytes.extend_from_slice(&id.to_le_bytes());
	}
	PosixAcl::new(&bytes)?;
	Ok(bytes)
}

// Match the pinned native converter's decimal grammar, including separators
// and signed zero, without allocating or accepting non-ASCII digits.
fn principal(name: &[u8]) -> Result<u32, Error> {
	let (negative, digits) = match name.first() {
		Some(b'+') => (false, &name[1..]),
		Some(b'-') => (true, &name[1..]),
		_ => (false, name),
	};
	if digits.is_empty() || digits.starts_with(b"_") || digits.ends_with(b"_") {
		return Err(Error::UnrepresentableAcl);
	}
	let mut value = 0u32;
	for &byte in digits {
		if byte == b'_' {
			continue;
		}
		if !byte.is_ascii_digit() || (negative && byte != b'0') {
			return Err(Error::UnrepresentableAcl);
		}
		value = value
			.checked_mul(10)
			.and_then(|n| n.checked_add(u32::from(byte - b'0')))
			.ok_or(Error::UnrepresentableAcl)?;
	}
	Ok(value)
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PosixAcl<'a> {
	bytes: &'a [u8],
}
impl<'a> PosixAcl<'a> {
	/// Validate Linux UAPI version/order, numeric principals and required entries.
	/// Work is linear in entries and requires no allocation.
	pub fn new(bytes: &'a [u8]) -> Result<Self, Error> {
		if bytes.is_empty() {
			return Ok(Self { bytes });
		}
		if bytes.len() < 4 || (bytes.len() - 4) % 8 != 0 || bytes[..4] != 2u32.to_le_bytes() {
			return Err(Error::InvalidAcl);
		}
		let (mut base, mut last_tag, mut last_id, mut named) = (0u8, 0u16, 0u32, false);
		for entry in bytes[4..].chunks_exact(8) {
			let raw_tag = u16::from_le_bytes([entry[0], entry[1]]);
			let permission = u16::from_le_bytes([entry[2], entry[3]]);
			let id = u32::from_le_bytes([entry[4], entry[5], entry[6], entry[7]]);
			if permission > 7 || raw_tag < last_tag {
				return Err(Error::InvalidAcl);
			}
			match tag(raw_tag)? {
				AceTag::NamedUser | AceTag::NamedGroup => {
					if id == u32::MAX || (raw_tag == last_tag && id <= last_id) {
						return Err(Error::InvalidAcl);
					}
					named = true;
				}
				kind @ (AceTag::Owner | AceTag::Group | AceTag::Mask | AceTag::Everyone) => {
					if id != u32::MAX || raw_tag == last_tag {
						return Err(Error::InvalidAcl);
					}
					base |= match kind {
						AceTag::Owner => 1,
						AceTag::Group => 2,
						AceTag::Mask => 4,
						AceTag::Everyone => 8,
						AceTag::NamedUser | AceTag::NamedGroup => 0,
					};
				}
			}
			last_tag = raw_tag;
			last_id = id;
		}
		if base & 11 != 11 || (named && base & 4 == 0) {
			return Err(Error::InvalidAcl);
		}
		Ok(Self { bytes })
	}
	pub fn bytes(self) -> &'a [u8] {
		self.bytes
	}
	pub fn portable(self) -> Result<Vec<Ace<'static>>, Error> {
		let mut aces = Vec::new();
		if self.bytes.is_empty() {
			return Ok(aces);
		}
		aces.try_reserve_exact((self.bytes.len() - 4) / 8)
			.map_err(|_| Error::OutOfMemory)?;
		for entry in self.bytes[4..].chunks_exact(8) {
			let tag = tag(u16::from_le_bytes([entry[0], entry[1]]))?;
			let permission = entry[2];
			let bits = ((permission & 4) >> 2) | (permission & 2) | ((permission & 1) << 2);
			let name = match tag {
				AceTag::NamedUser | AceTag::NamedGroup => {
					Cow::Owned(decimal(u32::from_le_bytes([
						entry[4], entry[5], entry[6], entry[7],
					]))?)
				}
				AceTag::Owner | AceTag::Group | AceTag::Mask | AceTag::Everyone => {
					Cow::Borrowed(b"".as_slice())
				}
			};
			aces.push(Ace {
				tag,
				permissions: Permissions::from_bits(bits).map_err(|_| Error::InvalidAcl)?,
				name,
			});
		}
		Ok(aces)
	}
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LinuxAcl<'a> {
	pub access: PosixAcl<'a>,
	pub default: PosixAcl<'a>,
}
impl<'a> LinuxAcl<'a> {
	pub fn encode(self) -> Result<Vec<u8>, Error> {
		let Self { access, default } = self;
		let a = u32::try_from(access.bytes.len()).map_err(|_| Error::InvalidAcl)?;
		let d = u32::try_from(default.bytes.len()).map_err(|_| Error::InvalidAcl)?;
		let length = access
			.bytes
			.len()
			.checked_add(default.bytes.len())
			.and_then(|n| n.checked_add(16))
			.ok_or(Error::InvalidAcl)?;
		let mut bytes = Vec::new();
		bytes
			.try_reserve_exact(length)
			.map_err(|_| Error::OutOfMemory)?;
		bytes.extend_from_slice(MAGIC);
		bytes.extend_from_slice(&a.to_le_bytes());
		bytes.extend_from_slice(&d.to_le_bytes());
		bytes.extend_from_slice(access.bytes);
		bytes.extend_from_slice(default.bytes);
		Ok(bytes)
	}
	pub fn decode(bytes: &'a [u8]) -> Result<Self, Error> {
		if bytes.len() < 16 || &bytes[..8] != MAGIC {
			return Err(Error::InvalidAcl);
		}
		let access = u32::from_le_bytes(bytes[8..12].try_into().map_err(|_| Error::InvalidAcl)?);
		let default = u32::from_le_bytes(bytes[12..16].try_into().map_err(|_| Error::InvalidAcl)?);
		if u64::from(access) + u64::from(default) != (bytes.len() - 16) as u64 {
			return Err(Error::InvalidAcl);
		}
		let boundary = 16 + usize::try_from(access).map_err(|_| Error::InvalidAcl)?;
		Ok(Self {
			access: PosixAcl::new(&bytes[16..boundary])?,
			default: PosixAcl::new(&bytes[boundary..])?,
		})
	}
}

fn tag(value: u16) -> Result<AceTag, Error> {
	match value {
		1 => Ok(AceTag::Owner),
		2 => Ok(AceTag::NamedUser),
		4 => Ok(AceTag::Group),
		8 => Ok(AceTag::NamedGroup),
		16 => Ok(AceTag::Mask),
		32 => Ok(AceTag::Everyone),
		_ => Err(Error::InvalidAcl),
	}
}
fn decimal(mut value: u32) -> Result<Vec<u8>, Error> {
	let mut digits = [0u8; 10];
	let mut begin = digits.len();
	loop {
		begin -= 1;
		digits[begin] = b'0' + (value % 10) as u8;
		value /= 10;
		if value == 0 {
			break;
		}
	}
	let mut bytes = Vec::new();
	bytes
		.try_reserve_exact(digits.len() - begin)
		.map_err(|_| Error::OutOfMemory)?;
	bytes.extend_from_slice(&digits[begin..]);
	Ok(bytes)
}
#[cfg(test)]
#[path = "linux_acl_tests.rs"]
mod tests;
