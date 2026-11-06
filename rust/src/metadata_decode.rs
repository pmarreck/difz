use super::{
	Ace, AceTag, AclOrigin, CanonicalMetadata, Error, Hole, Metadata, NativeAcl, Permissions, Time,
	Times, Xattr, XattrClass,
};
use alloc::{borrow::Cow, vec::Vec};

struct Cursor<'a> {
	bytes: &'a [u8],
	offset: usize,
}
impl<'a> Cursor<'a> {
	fn take(&mut self, length: usize) -> Result<&'a [u8], Error> {
		let end = self
			.offset
			.checked_add(length)
			.ok_or(Error::TruncatedMetadata)?;
		let bytes = self
			.bytes
			.get(self.offset..end)
			.ok_or(Error::TruncatedMetadata)?;
		self.offset = end;
		Ok(bytes)
	}
	fn array<const N: usize>(&mut self) -> Result<[u8; N], Error> {
		self.take(N)?
			.try_into()
			.map_err(|_| Error::TruncatedMetadata)
	}
	fn byte(&mut self) -> Result<u8, Error> {
		Ok(self.take(1)?[0])
	}
	fn u32(&mut self) -> Result<u32, Error> {
		Ok(u32::from_le_bytes(self.array()?))
	}
	fn u64(&mut self) -> Result<u64, Error> {
		Ok(u64::from_le_bytes(self.array()?))
	}
	fn blob(&mut self) -> Result<&'a [u8], Error> {
		let length = usize::try_from(self.u32()?).map_err(|_| Error::BadMetadata)?;
		self.take(length)
	}
	fn vector<T>(&mut self, minimum_record_bytes: usize) -> Result<(usize, Vec<T>), Error> {
		let count = usize::try_from(self.u32()?).map_err(|_| Error::BadMetadata)?;
		// Reject forged counts before requesting descriptor storage.
		if count > (self.bytes.len() - self.offset) / minimum_record_bytes {
			return Err(Error::TruncatedMetadata);
		}
		let mut values = Vec::new();
		values
			.try_reserve_exact(count)
			.map_err(|_| Error::OutOfMemory)?;
		Ok((count, values))
	}
	fn time(&mut self) -> Result<Time, Error> {
		Time::decode(self.take(12)?)
	}
}

impl<'a> CanonicalMetadata<'a> {
	/// Expected work is linear in encoded bytes and descriptors. Byte fields
	/// borrow the input; only checked descriptor arrays allocate storage.
	pub fn decode(bytes: &'a [u8]) -> Result<Self, Error> {
		let mut cursor = Cursor { bytes, offset: 0 };
		let (count, mut xattrs) = cursor.vector::<Xattr<'a>>(9)?;
		for _ in 0..count {
			let class = XattrClass::try_from(cursor.byte()?)?;
			let name = Cow::Borrowed(cursor.blob()?);
			let value = Cow::Borrowed(cursor.blob()?);
			xattrs.push(Xattr { class, name, value });
		}
		let (count, mut aces) = cursor.vector::<Ace<'a>>(6)?;
		for _ in 0..count {
			let tag = AceTag::try_from(cursor.byte()?)?;
			let permissions = Permissions::from_bits(cursor.byte()?)?;
			let name = Cow::Borrowed(cursor.blob()?);
			aces.push(Ace {
				tag,
				permissions,
				name,
			});
		}
		let origin = cursor.byte()?;
		let native_acl = if origin == 0 {
			None
		} else {
			let origin = AclOrigin::try_from(origin)?;
			Some(NativeAcl {
				origin,
				bytes: Cow::Borrowed(cursor.blob()?),
			})
		};
		let flags = cursor.byte()?;
		if flags & !7 != 0 {
			return Err(Error::BadMetadata);
		}
		let times = Times {
			mtime: if flags & 1 != 0 {
				Some(cursor.time()?)
			} else {
				None
			},
			atime: if flags & 2 != 0 {
				Some(cursor.time()?)
			} else {
				None
			},
			btime: if flags & 4 != 0 {
				Some(cursor.time()?)
			} else {
				None
			},
		};
		let finder_flags = cursor.u32()?;
		let finder_info = match cursor.byte()? {
			0 => None,
			1 => Some(cursor.array()?),
			_ => return Err(Error::BadMetadata),
		};
		let (count, mut holes) = cursor.vector::<Hole>(16)?;
		for _ in 0..count {
			holes.push(Hole {
				offset: cursor.u64()?,
				length: cursor.u64()?,
			});
		}
		let hardlink_to = match cursor.byte()? {
			0 => None,
			1 => Some(Cow::Borrowed(cursor.blob()?)),
			_ => return Err(Error::BadMetadata),
		};
		if cursor.offset != bytes.len() {
			return Err(Error::TrailingMetadata);
		}
		Self::new(Metadata {
			xattrs,
			aces,
			native_acl,
			times,
			finder_flags,
			finder_info,
			holes,
			hardlink_to,
		})
	}
}
