//! Linux canonical timestamp capture through opened objects.
use super::{Directory, EntryInfo, Error, xattr};
use difz_core::metadata::{self, Times, Xattr, XattrClass};
use std::{borrow::Cow, fs::File, io};
use xattr::ReadAttributes;

/// Capture kernel-visible user attributes. Transport, resource-fork and native
/// ACL records are handled by their respective families. A higher layer must
/// merge raw-attribute transport before constructing complete metadata.
/// The byte ceiling bounds native list bytes and retained name/value bytes
/// separately; count is checked by the native-list reader before capture.
pub fn capture_native_xattrs(
	file: &impl ReadAttributes,
	maximum_names: usize,
	maximum_bytes: usize,
) -> Result<Vec<Xattr<'static>>, Error> {
	let listed = match file.list(maximum_bytes, maximum_names) {
		Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOTSUP) => {
			return Ok(Vec::new());
		}
		other => other?,
	};
	let mut remaining = maximum_bytes;
	let mut output = Vec::new();
	for native in listed.iter() {
		let bare = native.strip_prefix(b"user.").unwrap_or(native);
		if metadata::is_transport_name(native)
			|| bare == b"com.apple.ResourceFork"
			|| native == b"system.posix_acl_access"
			|| native == b"system.posix_acl_default"
		{
			continue;
		}
		let (class, name) = match native.strip_prefix(b"user.") {
			Some(logical)
				if metadata::validate_xattr_name(XattrClass::Logical, logical).is_ok() =>
			{
				(XattrClass::Logical, logical)
			}
			_ => (XattrClass::Raw, native),
		};
		metadata::validate_xattr_name(class, name).map_err(Error::Metadata)?;
		if name.len() > remaining {
			return Err(Error::LimitExceeded);
		}
		let value = file.get(native, remaining - name.len())?.ok_or_else(|| {
			Error::Io(io::Error::new(
				io::ErrorKind::NotFound,
				"attribute disappeared during capture",
			))
		})?;
		remaining -= name.len() + value.len();
		let mut owned_name = Vec::new();
		owned_name
			.try_reserve_exact(name.len())
			.map_err(|_| Error::OutOfMemory)?;
		owned_name.extend_from_slice(name);
		output.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
		output.push(Xattr {
			class,
			name: Cow::Owned(owned_name),
			value: Cow::Owned(value),
		});
	}
	Ok(output)
}

/// Native modification and creation times with supported transport overrides.
/// Access time remains absent, matching native directory snapshots.
pub fn capture_times(file: &File) -> Result<Times, Error> {
	let info = EntryInfo::for_file(file)?;
	capture_times_for(info, file)
}
pub(crate) fn capture_times_for(
	info: EntryInfo,
	file: &impl ReadAttributes,
) -> Result<Times, Error> {
	let mut result = Times {
		mtime: Some(info.mtime),
		atime: None,
		btime: info.birth,
	};
	if let Some(bytes) = optional_transport(file, metadata::BIRTH_TIME_ATTRIBUTE, 13)? {
		result.btime = metadata::decode_time_override(&bytes).map_err(Error::Metadata)?;
	}
	if let Some(bytes) = optional_transport(file, metadata::MODIFICATION_TIME_ATTRIBUTE, 25)? {
		let witness = metadata::decode_modification_override(&bytes).map_err(Error::Metadata)?;
		if info.mtime == witness.observed {
			result.mtime = witness.original;
		}
	}
	Ok(result)
}
impl Directory {
	pub fn capture_times(&self) -> Result<Times, Error> {
		capture_times(&self.file)
	}
}
fn optional_transport(
	file: &impl ReadAttributes,
	logical: &[u8],
	maximum: usize,
) -> Result<Option<Vec<u8>>, Error> {
	let mut name = [0u8; 255];
	let prefix = b"user.";
	if logical.len() > name.len() - prefix.len() {
		return Err(Error::InvalidAttributeName);
	}
	name[..prefix.len()].copy_from_slice(prefix);
	let length = prefix.len() + logical.len();
	name[prefix.len()..length].copy_from_slice(logical);
	match file.get(&name[..length], maximum) {
		Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOTSUP) => Ok(None),
		other => other,
	}
}
