use super::*;
use crate::directory::{canonical_tests::fixture, structure};
use crate::metadata::tests::Reference;
use alloc::{format, vec, vec::Vec};

#[test]
fn structural_and_expanded_snapshot_validation_have_distinct_native_boundaries() {
	let mut reference = Reference::start();
	for selector in 0..=41 {
		// The existing canonical constructor tests exercise both million-entry
		// boundaries through this same validator; avoid duplicate large arrays.
		if selector == 26 || selector == 27 {
			continue;
		}
		let snapshot = fixture(selector);
		let result = structure::validate(&snapshot.entries)
			.map(|_| vec![])
			.map_err(|e| format!("{e:?}"));
		assert_eq!(
			result,
			reference.call(35, &[selector]),
			"fixture={selector}"
		);
		if [
			11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 23, 25, 28, 29, 30, 31, 32, 33, 34, 35, 36,
			37, 38, 39,
		]
		.contains(&selector)
		{
			assert!(
				result.is_ok(),
				"physical relations are deferred: {selector}"
			);
		}
	}
}
struct Raw<'a> {
	path: &'a [u8],
	mode: u16,
	kind: Kind,
	data: &'a [u8],
}
impl View for Raw<'_> {
	fn structure(&self) -> Record<'_> {
		let Self {
			path,
			mode,
			kind,
			data,
		} = self;
		Record {
			path,
			mode: *mode,
			kind: *kind,
			data,
		}
	}
}
#[test]
fn raw_wire_views_preserve_path_mode_payload_and_symlink_error_order() {
	let mut reference = Reference::start();
	for path in [b"x".as_slice(), b"../x", b"", b"\xff", b"\0", b"a/b"] {
		for mode in [0, 0o644, 0o777, 0o1000, u16::MAX] {
			for kind in [Kind::Directory, Kind::File, Kind::Symlink] {
				for data in [b"".as_slice(), b"file", b"\0\xff", b"../escape", b"."] {
					let raw = Raw {
						path,
						mode,
						kind,
						data,
					};
					let mut bytes = Vec::new();
					bytes.push(match kind {
						Kind::Directory => 1,
						Kind::File => 2,
						Kind::Symlink => 3,
					});
					bytes.extend_from_slice(&mode.to_le_bytes());
					bytes.extend_from_slice(&(path.len() as u32).to_le_bytes());
					bytes.extend_from_slice(path);
					bytes.extend_from_slice(data);
					assert_eq!(
						structure::validate(&[raw])
							.map(|_| vec![])
							.map_err(|e| format!("{e:?}")),
						reference.call(36, &bytes),
						"path={path:?} mode={mode:o} kind={kind:?} data={data:?}"
					);
				}
			}
		}
	}
}
