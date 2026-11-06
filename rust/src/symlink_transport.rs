//! Canonical per-parent transport for otherwise unsupported symlink metadata.
use crate::metadata::{
	CanonicalMetadata, Metadata, Time, Times, decode_time_override, encode_time_override,
};
use alloc::{borrow::Cow, vec::Vec};
pub const ATTRIBUTE: &[u8] = b"difz.symlinks";
pub const MAX_BYTES: usize = 65_536;
const MAGIC: &[u8; 9] = b"DIFZLINK\x01";
const MAX_RECORDS: usize = (MAX_BYTES - MAGIC.len() - 4) / 31;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	InvalidTransport,
	TransportTooLarge,
	OutOfMemory,
	Metadata(crate::metadata::Error),
}
#[derive(Debug)]
pub struct Record<'a> {
	pub name: Cow<'a, [u8]>,
	pub metadata: CanonicalMetadata<'a>,
	pub absent_times: u8,
	pub observed_mtime: Option<Time>,
	pub acl_override: bool,
	pub finder_override: bool,
}
#[derive(Debug)]
pub struct Transport<'a> {
	records: Vec<Record<'a>>,
}
impl<'a> Transport<'a> {
	/// Check sorted basenames and metadata/override relations without allocating.
	pub fn new(records: Vec<Record<'a>>) -> Result<Self, Error> {
		if records.len() > MAX_RECORDS {
			return Err(Error::TransportTooLarge);
		}
		for (index, record) in records.iter().enumerate() {
			validate(record)?;
			if index > 0 && records[index - 1].name >= record.name {
				return Err(Error::InvalidTransport);
			}
			encode_time_override(record.observed_mtime).map_err(Error::Metadata)?;
		}
		Ok(Self { records })
	}
	/// Linear in encoded bytes. Bound the entire output before reserving memory.
	pub fn encode(&self) -> Result<Vec<u8>, Error> {
		let mut length = MAGIC.len() + 4;
		for record in &self.records {
			let observed = encode_time_override(record.observed_mtime).map_err(Error::Metadata)?;
			let blob = record.metadata.encoded_len().map_err(Error::Metadata)?;
			for count in [9, observed.as_bytes().len(), record.name.len(), blob] {
				length = length.checked_add(count).ok_or(Error::TransportTooLarge)?;
				if length > MAX_BYTES {
					return Err(Error::TransportTooLarge);
				}
			}
		}
		let mut bytes = Vec::new();
		bytes
			.try_reserve_exact(length)
			.map_err(|_| Error::OutOfMemory)?;
		bytes.extend_from_slice(MAGIC);
		bytes.extend_from_slice(&(self.records.len() as u32).to_le_bytes());
		for Record {
			name,
			metadata,
			absent_times,
			observed_mtime,
			acl_override,
			finder_override,
		} in &self.records
		{
			let blob = metadata.encode().map_err(Error::Metadata)?;
			let observed = encode_time_override(*observed_mtime).map_err(Error::Metadata)?;
			bytes.extend_from_slice(&(name.len() as u32).to_le_bytes());
			bytes.extend_from_slice(&(blob.len() as u32).to_le_bytes());
			bytes.push(
				*absent_times | (u8::from(*acl_override) << 3) | (u8::from(*finder_override) << 4),
			);
			bytes.extend_from_slice(observed.as_bytes());
			bytes.extend_from_slice(name);
			bytes.extend_from_slice(&blob);
		}
		Ok(bytes)
	}
	/// Linear in the bounded input, borrowing all names and metadata byte fields.
	pub fn decode(bytes: &'a [u8]) -> Result<Self, Error> {
		if bytes.len() > MAX_BYTES {
			return Err(Error::TransportTooLarge);
		}
		let mut reader = Reader { bytes, position: 0 };
		if reader.take(MAGIC.len())? != MAGIC {
			return Err(Error::InvalidTransport);
		}
		let count = reader.word()?;
		if count > (bytes.len() - reader.position) / 31 {
			return Err(Error::InvalidTransport);
		}
		let mut records = Vec::new();
		records
			.try_reserve_exact(count)
			.map_err(|_| Error::OutOfMemory)?;
		for _ in 0..count {
			let name_len = reader.word()?;
			let meta_len = reader.word()?;
			let flags = reader.byte()?;
			if flags & 0xe0 != 0 {
				return Err(Error::InvalidTransport);
			}
			let begin = reader.position;
			match reader.byte()? {
				0 => {}
				1 => {
					reader.take(12)?;
				}
				_ => return Err(Error::InvalidTransport),
			}
			let observed_mtime = decode_time_override(&bytes[begin..reader.position])
				.map_err(|_| Error::InvalidTransport)?;
			let name = reader.take(name_len)?;
			let metadata =
				CanonicalMetadata::decode(reader.take(meta_len)?).map_err(|error| match error {
					crate::metadata::Error::OutOfMemory => Error::OutOfMemory,
					_ => Error::InvalidTransport,
				})?;
			let record = Record {
				name: Cow::Borrowed(name),
				metadata,
				absent_times: flags & 7,
				observed_mtime,
				acl_override: flags & 8 != 0,
				finder_override: flags & 16 != 0,
			};
			validate(&record)?;
			if records
				.last()
				.is_some_and(|previous: &Record<'_>| previous.name.as_ref() >= name)
			{
				return Err(Error::InvalidTransport);
			}
			records.push(record);
		}
		if reader.position != bytes.len() {
			return Err(Error::InvalidTransport);
		}
		Ok(Self { records })
	}
	pub fn records(&self) -> &[Record<'a>] {
		&self.records
	}
	pub fn find(&self, name: &[u8]) -> Option<&Record<'a>> {
		self.records
			.binary_search_by(|r| r.name.as_ref().cmp(name))
			.ok()
			.map(|i| &self.records[i])
	}
}

fn validate(record: &Record<'_>) -> Result<(), Error> {
	let Record {
		name,
		metadata,
		absent_times,
		observed_mtime,
		acl_override,
		finder_override,
	} = record;
	let Metadata {
		xattrs: _,
		aces: _,
		native_acl: _,
		times,
		finder_flags: _,
		finder_info: _,
		holes,
		hardlink_to,
	} = metadata.metadata();
	let Times {
		mtime,
		atime,
		btime,
	} = times;
	if (mtime.is_some() || absent_times & 1 != 0) != observed_mtime.is_some() {
		return Err(Error::InvalidTransport);
	}
	crate::directory::validate_path(name).map_err(|_| Error::InvalidTransport)?;
	if absent_times & !7 != 0
		|| [(1, mtime), (2, atime), (4, btime)]
			.iter()
			.any(|(bit, time)| absent_times & bit != 0 && time.is_some())
	{
		return Err(Error::InvalidTransport);
	}
	if name.contains(&b'/')
		|| (metadata.metadata().is_empty()
			&& *absent_times == 0
			&& !acl_override
			&& !finder_override)
		|| !holes.is_empty()
		|| hardlink_to.is_some()
	{
		return Err(Error::InvalidTransport);
	}
	Ok(())
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
			.ok_or(Error::InvalidTransport)?;
		let bytes = self
			.bytes
			.get(self.position..end)
			.ok_or(Error::InvalidTransport)?;
		self.position = end;
		Ok(bytes)
	}
	fn byte(&mut self) -> Result<u8, Error> {
		Ok(self.take(1)?[0])
	}
	fn word(&mut self) -> Result<usize, Error> {
		let bytes = self
			.take(4)?
			.try_into()
			.map_err(|_| Error::InvalidTransport)?;
		usize::try_from(u32::from_le_bytes(bytes)).map_err(|_| Error::InvalidTransport)
	}
}
#[cfg(test)]
#[path = "symlink_transport_tests.rs"]
mod tests;
