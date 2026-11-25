//! Order ordinary-object metadata effects before final stage permissions.
use crate::{
	Error, linux_acl_restore, linux_attribute_restore, linux_snapshot_metadata,
	linux_sparse_restore, linux_times, write,
};
use difz_core::{
	directory::Mode,
	metadata::{CanonicalMetadata, CompromiseCode, Family, Omit, RestoreReport},
};
use std::fs::File;

/// The caller owns a fresh staging object and must verify final capture before
/// publishing it. All children and payload writes precede this operation.
pub(crate) fn restore(
	file: &File,
	metadata: &CanonicalMetadata<'_>,
	mode: Mode,
	regular: bool,
	omit: Omit,
	limits: linux_snapshot_metadata::Limits,
	report: &mut RestoreReport,
) -> Result<(), Error> {
	for &family in Family::ALL {
		if omit.contains(family) {
			continue;
		}
		let value = match family {
			Family::Xattr => linux_attribute_restore::xattrs(
				file,
				metadata,
				limits.attributes,
				limits.metadata_bytes,
			)?,
			Family::Acl => {
				linux_acl_restore::prepare_for_mode(file, metadata, limits.metadata_bytes, mode)?
			}
			Family::Finder => {
				linux_attribute_restore::finder(file, metadata, limits.metadata_bytes)?
			}
			Family::Sparse if regular => linux_sparse_restore::restore(
				&mut file.try_clone()?,
				metadata,
				limits.extents,
				limits.metadata_bytes,
			)?,
			Family::Sparse | Family::Timestamps | Family::Hardlink => continue,
		};
		merge(report, value);
	}
	// Native punching and all structure writes precede the final time witness.
	if !omit.contains(Family::Timestamps) {
		merge(
			report,
			linux_times::restore(file, metadata.metadata().times)?,
		);
	}
	write::set_mode(file, mode)
}
fn merge(target: &mut RestoreReport, other: RestoreReport) {
	for &code in CompromiseCode::ALL {
		if other.bits() & (1 << (code as u8 - 1)) != 0 {
			target.add(code);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{Directory, tests::Fixture};
	use difz_core::metadata::{Metadata, Time, Times, Xattr, XattrClass};
	use std::{borrow::Cow, fs, io::Write, os::unix::fs::PermissionsExt};
	#[test]
	fn omitted_families_do_not_touch_attributes_or_attempt_unsupported_access_time() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		let mut file = parent.create_file(b"file").unwrap();
		file.write_all(b"retained").unwrap();
		fs::rename(fixture.0.join("file"), fixture.0.join("moved")).unwrap();
		parent.create_file(b"file").unwrap();
		let desired = CanonicalMetadata::new(Metadata {
			xattrs: vec![Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"data"),
				value: Cow::Borrowed(b"attribute"),
			}],
			times: Times {
				atime: Some(Time { sec: -7, nsec: 13 }),
				..Times::default()
			},
			finder_flags: 9,
			..Metadata::default()
		})
		.unwrap();
		let omit = Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap();
		let mut report = RestoreReport::default();
		restore(
			&file,
			&desired,
			Mode::from_bits(0o400).unwrap(),
			true,
			omit,
			linux_snapshot_metadata::Limits::default(),
			&mut report,
		)
		.unwrap();
		assert_eq!(report.bits(), 0);
		assert_eq!(
			fs::metadata(fixture.0.join("moved"))
				.unwrap()
				.permissions()
				.mode() & 0o777,
			0o400
		);
		assert_eq!(
			fs::metadata(fixture.0.join("file"))
				.unwrap()
				.permissions()
				.mode() & 0o777,
			0o600
		);
		assert_eq!(fs::read(fixture.0.join("moved")).unwrap(), b"retained");
	}
}
