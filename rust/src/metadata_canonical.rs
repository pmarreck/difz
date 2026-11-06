use super::{
	Ace, Error, Hole, Metadata, NativeAcl, Time, Times, Xattr, validate_ace_name,
	validate_hardlink, validate_xattr_name,
};
use alloc::vec::Vec;
use core::convert::Infallible;

/// Only validated records can be encoded or hashed. The borrowed view is
/// immutable, so callers cannot invalidate ordering or field constraints.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct CanonicalMetadata<'a>(Metadata<'a>);

impl<'a> CanonicalMetadata<'a> {
	pub fn new(metadata: Metadata<'a>) -> Result<Self, Error> {
		validate(&metadata)?;
		Ok(Self(metadata))
	}
	pub fn metadata(&self) -> &Metadata<'a> {
		&self.0
	}
	/// Expected work is linear in encoded bytes. Count before reserving output.
	pub fn encode(&self) -> Result<Vec<u8>, Error> {
		let mut length = 0usize;
		self.write::<Error>(|bytes| {
			length = length.checked_add(bytes.len()).ok_or(Error::BadMetadata)?;
			Ok(())
		})?;
		let mut output = Vec::new();
		output
			.try_reserve_exact(length)
			.map_err(|_| Error::OutOfMemory)?;
		self.write::<Error>(|bytes| {
			output.extend_from_slice(bytes);
			Ok(())
		})?;
		Ok(output)
	}
	/// Same field writer as encoding; expected work is linear in encoded bytes.
	pub fn hash(&self) -> [u8; 32] {
		let mut hasher = blake3::Hasher::new();
		hasher.update(b"DIFZMETA\x01");
		match self.write::<Infallible>(|bytes| {
			hasher.update(bytes);
			Ok(())
		}) {
			Ok(()) => {}
			Err(never) => match never {},
		}
		*hasher.finalize().as_bytes()
	}
	fn write<E>(&self, mut put: impl FnMut(&[u8]) -> Result<(), E>) -> Result<(), E> {
		let Metadata {
			xattrs,
			aces,
			native_acl,
			times,
			finder_flags,
			finder_info,
			holes,
			hardlink_to,
		} = &self.0;
		put(&(xattrs.len() as u32).to_le_bytes())?;
		for Xattr { class, name, value } in xattrs {
			put(&[*class as u8])?;
			put(&(name.len() as u32).to_le_bytes())?;
			put(name)?;
			put(&(value.len() as u32).to_le_bytes())?;
			put(value)?;
		}
		put(&(aces.len() as u32).to_le_bytes())?;
		for Ace {
			tag,
			permissions,
			name,
		} in aces
		{
			put(&[*tag as u8, permissions.bits()])?;
			put(&(name.len() as u32).to_le_bytes())?;
			put(name)?;
		}
		match native_acl {
			None => put(&[0])?,
			Some(NativeAcl { origin, bytes }) => {
				put(&[*origin as u8])?;
				put(&(bytes.len() as u32).to_le_bytes())?;
				put(bytes)?;
			}
		}
		let Times {
			mtime,
			atime,
			btime,
		} = times;
		let values = [*mtime, *atime, *btime];
		let flags = values.iter().enumerate().fold(0u8, |bits, (index, time)| {
			bits | (u8::from(time.is_some()) << index)
		});
		put(&[flags])?;
		for Time { sec, nsec } in values.into_iter().flatten() {
			put(&sec.to_le_bytes())?;
			put(&nsec.to_le_bytes())?;
		}
		put(&finder_flags.to_le_bytes())?;
		match finder_info {
			None => put(&[0])?,
			Some(bytes) => {
				put(&[1])?;
				put(bytes)?;
			}
		}
		put(&(holes.len() as u32).to_le_bytes())?;
		for Hole { offset, length } in holes {
			put(&offset.to_le_bytes())?;
			put(&length.to_le_bytes())?;
		}
		match hardlink_to {
			None => put(&[0])?,
			Some(path) => {
				put(&[1])?;
				put(&(path.len() as u32).to_le_bytes())?;
				put(path)?;
			}
		}
		Ok(())
	}
}

fn wire_length(length: usize) -> Result<(), Error> {
	u32::try_from(length)
		.map(|_| ())
		.map_err(|_| Error::BadMetadata)
}

// Expected work is linear in descriptors and names; blob values are borrowed.
fn validate(metadata: &Metadata<'_>) -> Result<(), Error> {
	let Metadata {
		xattrs,
		aces,
		native_acl,
		times,
		finder_flags: _,
		finder_info: _,
		holes,
		hardlink_to,
	} = metadata;
	wire_length(xattrs.len())?;
	for (index, Xattr { class, name, value }) in xattrs.iter().enumerate() {
		validate_xattr_name(*class, name)?;
		wire_length(value.len())?;
		if let Some(previous) = index.checked_sub(1).map(|i| &xattrs[i]) {
			if previous.class == *class && previous.name == *name {
				return Err(Error::DuplicateXattr);
			}
			if (previous.class, previous.name.as_ref()) >= (*class, name.as_ref()) {
				return Err(Error::BadMetadata);
			}
		}
	}
	wire_length(aces.len())?;
	for (
		index,
		Ace {
			tag,
			permissions: _,
			name,
		},
	) in aces.iter().enumerate()
	{
		validate_ace_name(*tag, name)?;
		wire_length(name.len())?;
		if let Some(previous) = index.checked_sub(1).map(|i| &aces[i]) {
			if previous.tag == *tag && previous.name == *name {
				return Err(Error::DuplicateAce);
			}
			if (previous.tag, previous.name.as_ref()) >= (*tag, name.as_ref()) {
				return Err(Error::BadMetadata);
			}
		}
	}
	if let Some(NativeAcl { origin: _, bytes }) = native_acl {
		if bytes.is_empty() {
			return Err(Error::EmptyNativeAcl);
		}
		wire_length(bytes.len())?;
	}
	let Times {
		mtime,
		atime,
		btime,
	} = times;
	for value in [*mtime, *atime, *btime].into_iter().flatten() {
		if value.nsec >= 1_000_000_000 {
			return Err(Error::InvalidNsec);
		}
	}
	wire_length(holes.len())?;
	let mut previous_end = None;
	for Hole { offset, length } in holes {
		if *length == 0 {
			return Err(Error::ZeroLengthHole);
		}
		let end = offset.checked_add(*length).ok_or(Error::HoleOverflow)?;
		if previous_end.is_some_and(|end| *offset <= end) {
			return Err(Error::BadMetadata);
		}
		previous_end = Some(end);
	}
	if let Some(path) = hardlink_to {
		validate_hardlink(path)?;
	}
	Ok(())
}
