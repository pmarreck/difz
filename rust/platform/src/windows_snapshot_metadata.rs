//! Explicit metadata-free Windows capture. Requested families fail closed.
pub use crate::metadata_limits::Limits;
use crate::{Directory, EntryInfo, Error, Identity, Kind};
use difz_core::metadata::{CanonicalMetadata, Family, Omit};
use std::{fs::File, io};

fn require_omitted(omit: Omit) -> Result<(), Error> {
	if Family::ALL.iter().any(|family| !omit.contains(*family)) {
		return Err(Error::UnsupportedMetadata);
	}
	Ok(())
}
fn empty(limits: Limits) -> Result<CanonicalMetadata<'static>, Error> {
	let metadata = CanonicalMetadata::default();
	if metadata.encoded_len().map_err(Error::Metadata)? > limits.metadata_bytes {
		return Err(Error::LimitExceeded);
	}
	Ok(metadata)
}
pub fn capture(
	file: File,
	omit: Omit,
	limits: Limits,
) -> Result<(EntryInfo, CanonicalMetadata<'static>), Error> {
	require_omitted(omit)?;
	let info = EntryInfo::for_file(&file)?;
	match info.kind {
		Kind::File | Kind::Directory => {}
		Kind::Symlink | Kind::Other => return Err(Error::WrongKind),
	}
	let metadata = empty(limits)?;
	if EntryInfo::for_file(&file)? != info {
		return Err(changed());
	}
	Ok((info, metadata))
}

pub struct ParentTransport {
	identity: Identity,
	limits: Limits,
}
impl ParentTransport {
	pub fn read(parent: &Directory, omit: Omit, limits: Limits) -> Result<Self, Error> {
		require_omitted(omit)?;
		empty(limits)?;
		Ok(Self {
			identity: parent.inspect_self()?.identity,
			limits,
		})
	}
	pub fn capture(
		&self,
		parent: &Directory,
		name: &[u8],
	) -> Result<(EntryInfo, CanonicalMetadata<'static>), Error> {
		if parent.inspect_self()?.identity != self.identity {
			return Err(changed());
		}
		let info = parent.inspect(name)?;
		if info.kind != Kind::Symlink {
			return Err(Error::WrongKind);
		}
		Ok((info, empty(self.limits)?))
	}
}
fn changed() -> Error {
	io::Error::new(
		io::ErrorKind::InvalidData,
		"object changed during metadata capture",
	)
	.into()
}
