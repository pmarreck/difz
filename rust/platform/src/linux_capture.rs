//! Linux ACL and portable metadata transport capture through opened objects.
use crate::{
	Error,
	linux_transport::{optional, owned},
	xattr::ReadAttributes,
};
use difz_core::{
	linux_acl::{LinuxAcl, PosixAcl},
	metadata::{AclOrigin, CanonicalMetadata, Metadata, NativeAcl},
};
use std::borrow::Cow;
#[cfg(test)]
use std::fs::File;

/// Native ACLs supply access ACEs and the access/default DIFZACL container.
/// Each optional canonical transport overrides only its designated field.
pub fn capture_acl(
	file: &impl ReadAttributes,
	maximum_bytes: usize,
) -> Result<Metadata<'static>, Error> {
	let mut result = capture_native_acl(file, maximum_bytes)?;
	apply_acl_transports(file, maximum_bytes, &mut result)?;
	Ok(result)
}

pub(crate) fn capture_native_acl(
	file: &impl ReadAttributes,
	maximum_bytes: usize,
) -> Result<Metadata<'static>, Error> {
	let access = optional(file, b"system.posix_acl_access", maximum_bytes)?.unwrap_or_default();
	let default = optional(
		file,
		b"system.posix_acl_default",
		maximum_bytes.saturating_sub(access.len()),
	)?
	.unwrap_or_default();
	let mut result = Metadata::default();
	if !access.is_empty() || !default.is_empty() {
		let access = PosixAcl::new(&access).map_err(acl_error)?;
		let default = PosixAcl::new(&default).map_err(acl_error)?;
		result.aces = access.portable().map_err(acl_error)?;
		result.native_acl = Some(NativeAcl {
			origin: AclOrigin::Linux,
			bytes: Cow::Owned(LinuxAcl { access, default }.encode().map_err(acl_error)?),
		});
	}
	Ok(result)
}

fn apply_acl_transports(
	file: &impl ReadAttributes,
	maximum_bytes: usize,
	result: &mut Metadata<'static>,
) -> Result<(), Error> {
	if let Some(bytes) = optional(file, b"user.difz.native-acl", maximum_bytes)? {
		let mut decoded = decode(&bytes)?;
		let acl = decoded.native_acl.take();
		require_empty(&decoded)?;
		result.native_acl = match acl {
			Some(NativeAcl { origin, bytes }) => Some(NativeAcl {
				origin,
				bytes: Cow::Owned(owned(&bytes)?),
			}),
			None => None,
		};
	}
	if let Some(bytes) = optional(file, b"user.difz.portable-acl", maximum_bytes)? {
		let mut decoded = decode(&bytes)?;
		let aces = std::mem::take(&mut decoded.aces);
		require_empty(&decoded)?;
		result.aces.clear();
		result
			.aces
			.try_reserve_exact(aces.len())
			.map_err(|_| Error::OutOfMemory)?;
		for ace in aces {
			result.aces.push(difz_core::metadata::Ace {
				tag: ace.tag,
				permissions: ace.permissions,
				name: Cow::Owned(owned(&ace.name)?),
			});
		}
	}
	Ok(())
}

/// Linux has no native Finder fields. A present transport may explicitly
/// override either field with its empty value, but cannot carry other fields.
pub fn capture_finder(
	file: &impl ReadAttributes,
	maximum_bytes: usize,
) -> Result<Metadata<'static>, Error> {
	let mut result = Metadata::default();
	if let Some(bytes) = optional(file, b"user.difz.bsd-flags", maximum_bytes)? {
		let mut decoded = decode(&bytes)?;
		result.finder_flags = std::mem::take(&mut decoded.finder_flags);
		require_empty(&decoded)?;
	}
	if let Some(bytes) = optional(file, b"user.difz.finder-info", maximum_bytes)? {
		let mut decoded = decode(&bytes)?;
		result.finder_info = decoded.finder_info.take();
		require_empty(&decoded)?;
	}
	Ok(result)
}

pub fn capture_hardlink(
	file: &impl ReadAttributes,
	maximum_bytes: usize,
) -> Result<Option<Vec<u8>>, Error> {
	let Some(bytes) = optional(file, b"user.difz.hardlink-to", maximum_bytes)? else {
		return Ok(None);
	};
	let mut decoded = decode(&bytes)?;
	let path = decoded
		.hardlink_to
		.take()
		.ok_or(Error::Metadata(difz_core::metadata::Error::BadMetadata))?;
	// Canonical decoding already validated the relative link path.
	let path = owned(&path)?;
	// The remainder cannot contain another metadata family.
	require_empty(&decoded)?;
	Ok(Some(path))
}

fn decode(bytes: &[u8]) -> Result<Metadata<'_>, Error> {
	Ok(CanonicalMetadata::decode(bytes)
		.map_err(Error::Metadata)?
		.into_metadata())
}
fn require_empty(metadata: &Metadata<'_>) -> Result<(), Error> {
	if metadata.is_empty() {
		Ok(())
	} else {
		Err(Error::Metadata(difz_core::metadata::Error::BadMetadata))
	}
}
fn acl_error(error: difz_core::linux_acl::Error) -> Error {
	match error {
		difz_core::linux_acl::Error::OutOfMemory => Error::OutOfMemory,
		difz_core::linux_acl::Error::InvalidAcl
		| difz_core::linux_acl::Error::UnrepresentableAcl => {
			Error::Metadata(difz_core::metadata::Error::BadMetadata)
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{linux_transport::capture_xattrs, tests::Fixture};
	use difz_core::metadata::{Omit, Xattr, XattrClass};
	use std::{ffi::CString, fs, os::fd::AsRawFd};
	fn set(file: &File, name: &[u8], bytes: &[u8]) {
		let name = CString::new(name).unwrap();
		// The direct kernel fixture is independent of the production writer.
		let rc = unsafe {
			libc::fsetxattr(
				file.as_raw_fd(),
				name.as_ptr(),
				bytes.as_ptr().cast(),
				bytes.len(),
				0,
			)
		};
		assert_eq!(rc, 0, "{}", std::io::Error::last_os_error());
	}
	fn wire(metadata: Metadata<'_>) -> Vec<u8> {
		CanonicalMetadata::normalize(metadata, Omit::default())
			.unwrap()
			.encode()
			.unwrap()
	}
	fn file(fixture: &Fixture) -> File {
		fs::write(fixture.0.join("data"), b"binary\0file").unwrap();
		File::open(fixture.0.join("data")).unwrap()
	}
	#[test]
	fn native_raw_capture_merges_transport_and_survives_path_replacement() {
		let fixture = Fixture::new();
		let file = file(&fixture);
		set(&file, b"user.binary\xff", b"kernel\0value");
		let mut sidecar = Metadata::default();
		for (name, value) in [
			(b"user.binary\xff".as_slice(), b"stale".as_slice()),
			(b"foreign\xff", b"\0\xfftransport"),
		] {
			sidecar.xattrs.push(Xattr {
				class: XattrClass::Raw,
				name: Cow::Borrowed(name),
				value: Cow::Borrowed(value),
			});
		}
		set(&file, b"user.difz.raw-xattrs", &wire(sidecar));
		fs::rename(fixture.0.join("data"), fixture.0.join("original")).unwrap();
		fs::write(fixture.0.join("data"), b"replacement").unwrap();
		let captured = capture_xattrs(&file, 128, 4096).unwrap();
		assert!(
			captured
				.iter()
				.any(|a| a.name.as_ref() == b"user.binary\xff"
					&& a.value.as_ref() == b"kernel\0value")
		);
		assert!(
			captured.iter().any(
				|a| a.name.as_ref() == b"foreign\xff" && a.value.as_ref() == b"\0\xfftransport"
			)
		);
		assert_eq!(
			captured
				.iter()
				.filter(|a| a.name.as_ref() == b"user.binary\xff")
				.count(),
			1
		);
		assert!(
			capture_xattrs(&File::open(fixture.0.join("data")).unwrap(), 128, 4096)
				.unwrap()
				.is_empty()
		);
		set(&file, b"user.difz.raw-xattrs", b"bad transport");
		assert!(matches!(
			capture_xattrs(&file, 128, 4096),
			Err(Error::Metadata(_))
		));
	}
	#[test]
	fn native_acl_capture_matches_kernel_bytes_and_explicit_empty_overrides() {
		let fixture = Fixture::new();
		let file = file(&fixture);
		// The isolated user namespace maps the current UID. An arbitrary host
		// UID can be unmapped there, causing the kernel to reject the fixture.
		let principal = unsafe { libc::getuid() };
		let mut bytes = 2u32.to_le_bytes().to_vec();
		for (tag, permissions, id) in [
			(1u16, 6u16, u32::MAX),
			(2, 4, principal),
			(4, 4, u32::MAX),
			(16, 4, u32::MAX),
			(32, 0, u32::MAX),
		] {
			bytes.extend_from_slice(&tag.to_le_bytes());
			bytes.extend_from_slice(&permissions.to_le_bytes());
			bytes.extend_from_slice(&id.to_le_bytes());
		}
		set(&file, b"system.posix_acl_access", &bytes);
		let captured = capture_acl(&file, 4096).unwrap();
		let acl = captured.native_acl.as_ref().unwrap();
		assert_eq!(acl.origin, AclOrigin::Linux);
		assert_eq!(LinuxAcl::decode(&acl.bytes).unwrap().access.bytes(), bytes);
		assert_eq!(captured.aces.len(), 5);
		let named = captured
			.aces
			.iter()
			.find(|a| a.tag == difz_core::metadata::AceTag::NamedUser)
			.unwrap();
		assert_eq!(named.name.as_ref(), principal.to_string().as_bytes());
		assert_eq!(named.permissions, difz_core::metadata::Permissions::READ);
		set(&file, b"user.difz.native-acl", &wire(Metadata::default()));
		set(&file, b"user.difz.portable-acl", &wire(Metadata::default()));
		let empty = capture_acl(&file, 4096).unwrap();
		assert!(empty.native_acl.is_none() && empty.aces.is_empty());
		set(
			&file,
			b"user.difz.portable-acl",
			&wire(Metadata {
				finder_flags: 1,
				..Metadata::default()
			}),
		);
		assert!(matches!(capture_acl(&file, 4096), Err(Error::Metadata(_))));
		assert!(matches!(capture_acl(&file, 1), Err(Error::LimitExceeded)));
		// Default ACLs belong to directories and must remain separate from
		// canonical raw attributes, even when no access ACL is present.
		let directory = File::open(&fixture.0).unwrap();
		set(&directory, b"system.posix_acl_default", &bytes);
		let captured = capture_acl(&directory, 4096).unwrap();
		let acl = captured.native_acl.as_ref().unwrap();
		assert_eq!(LinuxAcl::decode(&acl.bytes).unwrap().default.bytes(), bytes);
		assert!(
			capture_xattrs(&directory, 128, 4096)
				.unwrap()
				.iter()
				.all(|attr| attr.name.as_ref() != b"system.posix_acl_default")
		);
	}
	#[test]
	fn native_acl_transport_owns_foreign_bytes_and_principal_names() {
		let fixture = Fixture::new();
		let file = file(&fixture);
		set(
			&file,
			b"user.difz.native-acl",
			&wire(Metadata {
				native_acl: Some(NativeAcl {
					origin: AclOrigin::Mswin,
					bytes: Cow::Borrowed(b"\0\xffopaque"),
				}),
				..Metadata::default()
			}),
		);
		set(
			&file,
			b"user.difz.portable-acl",
			&wire(Metadata {
				aces: vec![difz_core::metadata::Ace {
					tag: difz_core::metadata::AceTag::NamedUser,
					permissions: difz_core::metadata::Permissions::READ,
					name: Cow::Borrowed(b"12345"),
				}],
				..Metadata::default()
			}),
		);
		let captured = capture_acl(&file, 4096).unwrap();
		set(&file, b"user.difz.native-acl", &wire(Metadata::default()));
		set(&file, b"user.difz.portable-acl", &wire(Metadata::default()));
		drop(file);
		let acl = captured.native_acl.unwrap();
		assert_eq!(acl.origin, AclOrigin::Mswin);
		assert_eq!(acl.bytes.as_ref(), b"\0\xffopaque");
		assert!(matches!(acl.bytes, Cow::Owned(_)));
		assert_eq!(captured.aces[0].name.as_ref(), b"12345");
		assert!(matches!(captured.aces[0].name, Cow::Owned(_)));
	}
	#[test]
	fn native_finder_and_hardlink_capture_reject_mixed_family_transport() {
		let fixture = Fixture::new();
		let file = file(&fixture);
		set(
			&file,
			b"user.difz.bsd-flags",
			&wire(Metadata {
				finder_flags: 0x8001,
				..Metadata::default()
			}),
		);
		set(
			&file,
			b"user.difz.finder-info",
			&wire(Metadata {
				finder_info: Some([0xff; 32]),
				..Metadata::default()
			}),
		);
		let finder = capture_finder(&file, 4096).unwrap();
		assert_eq!(finder.finder_flags, 0x8001);
		assert_eq!(finder.finder_info, Some([0xff; 32]));
		set(
			&file,
			b"user.difz.finder-info",
			&wire(Metadata {
				finder_flags: 1,
				finder_info: Some([0; 32]),
				..Metadata::default()
			}),
		);
		assert!(matches!(
			capture_finder(&file, 4096),
			Err(Error::Metadata(_))
		));
		set(
			&file,
			b"user.difz.hardlink-to",
			&wire(Metadata {
				hardlink_to: Some(Cow::Borrowed(b"dir/base")),
				..Metadata::default()
			}),
		);
		assert_eq!(capture_hardlink(&file, 4096).unwrap().unwrap(), b"dir/base");
		set(&file, b"user.difz.hardlink-to", &wire(Metadata::default()));
		assert!(matches!(
			capture_hardlink(&file, 4096),
			Err(Error::Metadata(_))
		));
		set(
			&file,
			b"user.difz.hardlink-to",
			&wire(Metadata {
				hardlink_to: Some(Cow::Borrowed(b"dir/base")),
				finder_flags: 1,
				..Metadata::default()
			}),
		);
		assert!(matches!(
			capture_hardlink(&file, 4096),
			Err(Error::Metadata(_))
		));
	}
}
