//! Native ACL restoration with explicit canonical transport after readback.
use crate::{EntryInfo, Error, Kind, linux_capture, xattr};
use difz_core::{
	directory::Mode,
	linux_acl::{self, LinuxAcl},
	metadata::{CanonicalMetadata, CompromiseCode, Family, Metadata, Omit, Os, RestoreReport},
};
use std::{fs::File, io};

/// Restore only the ACL family on an owned staging object. Call after its last
/// permission change, which may otherwise rewrite the native ACL's mask.
/// The enclosing stage owns rollback if a later operation fails.
pub fn restore(
	file: &File,
	desired: &CanonicalMetadata<'_>,
	maximum_bytes: usize,
) -> Result<RestoreReport, Error> {
	restore_inner(file, desired, maximum_bytes, None)
}

/// Prepare transports for the ACL that the final chmod will produce, then
/// leave the private object writable for remaining stage metadata. The caller
/// must set final_mode again and verify the complete stage before publication.
pub fn prepare_for_mode(
	file: &File,
	desired: &CanonicalMetadata<'_>,
	maximum_bytes: usize,
	final_mode: Mode,
) -> Result<RestoreReport, Error> {
	restore_inner(file, desired, maximum_bytes, Some(final_mode))
}

fn restore_inner(
	file: &File,
	desired: &CanonicalMetadata<'_>,
	maximum_bytes: usize,
	final_mode: Option<Mode>,
) -> Result<RestoreReport, Error> {
	let kind = EntryInfo::for_file(file)?.kind;
	match kind {
		Kind::File | Kind::Directory => {}
		Kind::Symlink | Kind::Other => return Err(Error::WrongKind),
	}
	let excluded = Family::ALL
		.iter()
		.filter(|&&family| family != Family::Acl)
		.fold(0, |bits, family| bits | family.bit());
	let desired = desired
		.borrowing_omitting(Omit::from_bits(excluded).map_err(Error::Metadata)?)
		.map_err(Error::Metadata)?;
	if desired.encoded_len().map_err(Error::Metadata)? > maximum_bytes {
		return Err(Error::LimitExceeded);
	}
	let expected_hash = desired.hash();
	// Canonical transports are replaced only on the caller's owned stage.
	remove(file, b"user.difz.native-acl")?;
	remove(file, b"user.difz.portable-acl")?;
	// Inherited permissions must not remain active behind a canonical transport.
	// Clearing the owned stage must succeed even when the desired ACL cannot
	// be represented natively; otherwise an unrelated inherited grant survives.
	remove(file, b"system.posix_acl_access")?;
	remove(file, b"system.posix_acl_default")?;
	apply_native(file, &desired)?;
	let native = if let Some(mode) = final_mode {
		crate::write::set_mode(file, mode)?;
		// No user transports exist yet. Reading only native ACL names also
		// works for a final mode that disallows reading user attributes.
		let captured = linux_capture::capture_native_acl(file, maximum_bytes);
		crate::write::set_mode(
			file,
			Mode::from_bits(if kind == Kind::Directory {
				0o700
			} else {
				0o600
			})
			.map_err(Error::Snapshot)?,
		)?;
		captured?
	} else {
		linux_capture::capture_acl(file, maximum_bytes)?
	};
	let actual = CanonicalMetadata::normalize(native, Omit::default())
		.map_err(Error::Metadata)?
		.into_metadata();
	let mut expected = desired.into_metadata();
	let mut report = RestoreReport::default();
	if actual.native_acl != expected.native_acl {
		write(
			file,
			b"user.difz.native-acl",
			Metadata {
				native_acl: expected.native_acl.take(),
				..Metadata::default()
			},
		)?;
		report.add(CompromiseCode::NativeAclPreserved);
	}
	if actual.aces != expected.aces {
		write(
			file,
			b"user.difz.portable-acl",
			Metadata {
				aces: std::mem::take(&mut expected.aces),
				..Metadata::default()
			},
		)?;
		report.add(CompromiseCode::PortableAclPreserved);
	}
	if final_mode.is_some() {
		return Ok(report);
	}
	let captured = CanonicalMetadata::normalize(
		linux_capture::capture_acl(file, maximum_bytes)?,
		Omit::default(),
	)
	.map_err(Error::Metadata)?;
	if captured.hash() != expected_hash {
		return Err(io::Error::new(io::ErrorKind::InvalidData, "ACL readback changed").into());
	}
	Ok(report)
}

fn apply_native(file: &File, desired: &CanonicalMetadata<'_>) -> Result<(), Error> {
	if let Some(acl) = &desired.metadata().native_acl {
		if acl.origin == Os::Linux {
			if let Ok(native) = LinuxAcl::decode(&acl.bytes) {
				best_effort(replace(
					file,
					b"system.posix_acl_access",
					native.access.bytes(),
				))?;
				best_effort(replace(
					file,
					b"system.posix_acl_default",
					native.default.bytes(),
				))?;
			}
			return Ok(());
		}
	}
	match linux_acl::encode_portable(desired) {
		Ok(bytes) => {
			best_effort(replace(file, b"system.posix_acl_access", &bytes))?;
			best_effort(remove(file, b"system.posix_acl_default"))?;
		}
		Err(linux_acl::Error::OutOfMemory) => return Err(Error::OutOfMemory),
		Err(linux_acl::Error::InvalidAcl | linux_acl::Error::UnrepresentableAcl) => {}
	}
	Ok(())
}
fn best_effort(result: Result<(), Error>) -> Result<(), Error> {
	match result {
		Err(Error::OutOfMemory) => Err(Error::OutOfMemory),
		_ => Ok(()),
	}
}
fn replace(file: &File, name: &[u8], bytes: &[u8]) -> Result<(), Error> {
	if bytes.is_empty() {
		remove(file, name)
	} else {
		xattr::set(file, name, bytes)
	}
}
fn remove(file: &File, name: &[u8]) -> Result<(), Error> {
	match xattr::remove(file, name) {
		Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOTSUP) => Ok(()),
		result => result.map(|_| ()),
	}
}
fn write(file: &File, name: &[u8], metadata: Metadata<'_>) -> Result<(), Error> {
	let bytes = CanonicalMetadata::new(metadata)
		.map_err(Error::Metadata)?
		.encode()
		.map_err(Error::Metadata)?;
	xattr::set(file, name, &bytes)?;
	if xattr::get(file, name, bytes.len())?.as_deref() != Some(bytes.as_slice()) {
		return Err(io::Error::new(
			io::ErrorKind::InvalidData,
			"ACL transport readback mismatch",
		)
		.into());
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{Directory, tests::Fixture};
	use difz_core::metadata::{Ace, AceTag, NativeAcl, Permissions};
	use std::{
		borrow::Cow,
		fs,
		os::{fd::AsRawFd, unix::fs::PermissionsExt},
	};
	fn kernel_acl() -> Vec<u8> {
		let mut bytes = 2u32.to_le_bytes().to_vec();
		for (tag, permissions, id) in [
			(1u16, 6u16, u32::MAX),
			(2, 4, unsafe { libc::getuid() }),
			(4, 4, u32::MAX),
			(16, 4, u32::MAX),
			(32, 0, u32::MAX),
		] {
			bytes.extend_from_slice(&tag.to_le_bytes());
			bytes.extend_from_slice(&permissions.to_le_bytes());
			bytes.extend_from_slice(&id.to_le_bytes());
		}
		bytes
	}
	#[test]
	fn native_acl_restore_matches_kernel_bytes_after_open_path_replacement_and_clears_absence() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		let source = parent.create_file(b"source").unwrap();
		let bytes = kernel_acl();
		assert_eq!(
			unsafe {
				libc::fsetxattr(
					source.as_raw_fd(),
					c"system.posix_acl_access".as_ptr(),
					bytes.as_ptr().cast(),
					bytes.len(),
					0,
				)
			},
			0
		);
		let desired = CanonicalMetadata::normalize(
			linux_capture::capture_acl(&source, 65_536).unwrap(),
			Omit::default(),
		)
		.unwrap();
		let target = parent.create_file(b"target").unwrap();
		fs::rename(fixture.0.join("target"), fixture.0.join("moved")).unwrap();
		parent.create_file(b"target").unwrap();
		assert_eq!(restore(&target, &desired, 65_536).unwrap().bits(), 0);
		let mut raw = [0u8; 128];
		let length = unsafe {
			libc::fgetxattr(
				target.as_raw_fd(),
				c"system.posix_acl_access".as_ptr(),
				raw.as_mut_ptr().cast(),
				raw.len(),
			)
		};
		assert_eq!(length as usize, bytes.len());
		assert_eq!(&raw[..bytes.len()], bytes);
		assert_eq!(
			CanonicalMetadata::normalize(
				linux_capture::capture_acl(&target, 65_536).unwrap(),
				Omit::default()
			)
			.unwrap(),
			desired
		);
		assert!(
			xattr::get(
				&parent.open_regular_file(b"target").unwrap(),
				b"system.posix_acl_access",
				65_536
			)
			.unwrap()
			.is_none()
		);
		restore(&target, &CanonicalMetadata::default(), 65_536).unwrap();
		assert!(
			linux_capture::capture_acl(&target, 65_536)
				.unwrap()
				.is_empty()
		);
	}
	#[test]
	fn native_foreign_acl_and_non_numeric_portable_principal_use_exact_field_transports() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		// A fresh staging file can inherit active entries even though its owner
		// did not explicitly set an ACL. The foreign fallback must clear them.
		xattr::set(&parent.file, b"system.posix_acl_default", &kernel_acl()).unwrap();
		let file = parent.create_file(b"data").unwrap();
		assert!(
			xattr::get(&file, b"system.posix_acl_access", 65_536)
				.unwrap()
				.is_some()
		);
		let desired = CanonicalMetadata::normalize(
			Metadata {
				native_acl: Some(NativeAcl {
					origin: Os::Macos,
					bytes: Cow::Borrowed(b"foreign\0binary\xff"),
				}),
				aces: vec![Ace {
					tag: AceTag::NamedUser,
					permissions: Permissions::READ,
					name: Cow::Borrowed(b"not-a-numeric-id"),
				}],
				..Metadata::default()
			},
			Omit::default(),
		)
		.unwrap();
		let report = restore(&file, &desired, 65_536).unwrap();
		for code in [
			CompromiseCode::NativeAclPreserved,
			CompromiseCode::PortableAclPreserved,
		] {
			assert_ne!(report.bits() & (1 << (code as u8 - 1)), 0);
		}
		assert_eq!(
			linux_capture::capture_acl(&file, 65_536).unwrap(),
			desired.into_metadata()
		);
		let mut native = [0u8; 128];
		let count = unsafe {
			libc::fgetxattr(
				file.as_raw_fd(),
				c"system.posix_acl_access".as_ptr(),
				native.as_mut_ptr().cast(),
				native.len(),
			)
		};
		assert_eq!(
			count, -1,
			"foreign transport retained an inherited active ACL"
		);
		assert_eq!(
			io::Error::last_os_error().raw_os_error(),
			Some(libc::ENODATA)
		);
	}
	#[test]
	fn native_private_creation_restores_owner_permissions_restricted_by_parent_default_acl() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		for owner_bits in [4u16, 6] {
			let mut acl = kernel_acl();
			acl[6..8].copy_from_slice(&owner_bits.to_le_bytes());
			xattr::set(&parent.file, b"system.posix_acl_default", &acl).unwrap();
			let name = format!("private-{owner_bits}");
			let directory = parent.create_directory(name.as_bytes()).unwrap();
			assert_eq!(
				directory.file.metadata().unwrap().permissions().mode() & 0o777,
				0o700,
				"parent default ACL removed private directory owner permissions"
			);
			let file = directory.create_file(b"data").unwrap();
			assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o600);
			xattr::set(&file, b"user.private-probe", b"\0\xff").unwrap();
			let mut raw = [0u8; 2];
			assert_eq!(
				unsafe {
					libc::fgetxattr(
						file.as_raw_fd(),
						c"user.private-probe".as_ptr(),
						raw.as_mut_ptr().cast(),
						raw.len(),
					)
				},
				2
			);
			assert_eq!(raw, [0, 255]);
		}
	}
	#[test]
	fn native_stage_acl_preparation_preserves_requested_acl_across_final_mode_changes() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		let source = root.create_file(b"source").unwrap();
		xattr::set(&source, b"system.posix_acl_access", &kernel_acl()).unwrap();
		let desired = CanonicalMetadata::normalize(
			linux_capture::capture_acl(&source, 65_536).unwrap(),
			Omit::default(),
		)
		.unwrap();
		for bits in [0, 0o400, 0o600, 0o640] {
			let name = format!("mode-{bits}");
			let target = root.create_file(name.as_bytes()).unwrap();
			let mode = Mode::from_bits(bits).unwrap();
			prepare_for_mode(&target, &desired, 65_536, mode).unwrap();
			assert_eq!(EntryInfo::for_file(&target).unwrap().mode.bits(), 0o600);
			crate::write::set_mode(&target, mode).unwrap();
			assert_eq!(
				target.metadata().unwrap().permissions().mode() & 0o777,
				u32::from(bits)
			);
			// The zero-mode object cannot expose user transports until read
			// permission returns. Its final native ACL mask is read directly.
			let raw = xattr::get(&target, b"system.posix_acl_access", 65_536)
				.unwrap()
				.unwrap();
			let mask = raw[4..]
				.chunks_exact(8)
				.find(|entry| entry[..2] == 16u16.to_le_bytes())
				.unwrap();
			assert_eq!(u16::from_le_bytes([mask[2], mask[3]]), (bits >> 3) & 7);
			crate::write::set_mode(&target, Mode::from_bits(bits | 0o400).unwrap()).unwrap();
			assert_eq!(
				CanonicalMetadata::normalize(
					linux_capture::capture_acl(&target, 65_536).unwrap(),
					Omit::default()
				)
				.unwrap(),
				desired
			);
		}
	}
	#[test]
	fn acl_restore_rejects_byte_limit_before_modifying_the_object() {
		let fixture = Fixture::new();
		let file = Directory::open(&fixture.0)
			.unwrap()
			.create_file(b"data")
			.unwrap();
		assert!(matches!(
			restore(&file, &CanonicalMetadata::default(), 19),
			Err(Error::LimitExceeded)
		));
		match xattr::get(&file, b"user.difz.native-acl", 65_536) {
			Ok(value) => assert!(value.is_none()),
			Err(Error::Io(error)) => assert_eq!(error.raw_os_error(), Some(libc::ENOTSUP)),
			other => panic!("unexpected readback: {other:?}"),
		}
	}
}
