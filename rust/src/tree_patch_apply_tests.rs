use super::*;
use crate::directory::{Content, Entry, Mode, Snapshot};
use crate::metadata::CanonicalMetadata;
use crate::{
	metadata::tests::Reference,
	tree_patch::{CreateOptions, create, encode::tests::fixture},
};
use alloc::borrow::Cow;
use alloc::{format, string::String, vec, vec::Vec};

fn native_error(error: Error) -> String {
	match error {
		Error::Metadata(error) => format!("{error:?}"),
		Error::Snapshot(error) => format!("{error:?}"),
		Error::Filter(error) => format!("{error:?}"),
		Error::File(error) => format!("{error:?}"),
		other => format!("{other:?}"),
	}
}
fn compare(
	reference: &mut Reference,
	source: &CanonicalSnapshot<'_>,
	selector: u8,
	bytes: &[u8],
	maximum: u64,
) {
	let mut request = vec![selector];
	request.extend_from_slice(&maximum.to_le_bytes());
	request.extend_from_slice(bytes);
	let actual = apply(
		source,
		bytes,
		ApplyLimits {
			max_output_bytes: maximum,
			..ApplyLimits::default()
		},
	)
	.map(|tree| tree.hash().to_vec())
	.map_err(native_error);
	assert_eq!(
		actual,
		reference.call(45, &request),
		"maximum={maximum} patch={bytes:?}"
	);
}
fn reseal(bytes: &mut [u8]) {
	let mut hash = blake3::Hasher::new();
	hash.update(b"DIFZTREE-PATCH\x02");
	hash.update(&bytes[..88]);
	hash.update(&bytes[120..]);
	bytes[88..120].copy_from_slice(hash.finalize().as_bytes());
}
#[test]
fn directory_cross_apply_matches_native_for_every_omission_mask_and_output_bound() {
	let mut reference = Reference::start();
	let source = fixture(false);
	let target = fixture(true);
	for mask in 0..64 {
		let native = reference.call(40, &[4, mask]).unwrap();
		let limits = ApplyLimits::default();
		let actual = apply(&source, &native, limits).unwrap();
		assert_eq!(
			actual.hash(),
			crate::tree_patch::encode::project(
				&target,
				crate::metadata::Omit::from_bits(mask as u32).unwrap()
			)
			.unwrap()
			.hash()
		);
		for maximum in [0, 3, 6, 7, 20, 21, 24, 25, 26, 27] {
			compare(&mut reference, &source, 1, &native, maximum);
		}
		let rust = create(
			&source,
			&target,
			CreateOptions {
				omit: crate::metadata::Omit::from_bits(mask as u32).unwrap(),
				..CreateOptions::default()
			},
		)
		.unwrap();
		compare(&mut reference, &source, 1, &rust, limits.max_output_bytes);
	}
	let empty = CanonicalSnapshot::default();
	for selector in 0..=3 {
		let bytes = reference.call(40, &[selector]).unwrap();
		for maximum in [0, 5, 6, 7] {
			compare(&mut reference, &empty, 0, &bytes, maximum);
		}
	}
}
#[test]
fn apply_rejects_wrong_identities_and_resealed_delta_corruption_like_native() {
	let mut reference = Reference::start();
	let source = fixture(false);
	let bytes = reference.call(40, &[4]).unwrap();
	compare(
		&mut reference,
		&CanonicalSnapshot::default(),
		0,
		&bytes,
		64 << 30,
	);
	for offset in [24, 56] {
		let mut altered = bytes.clone();
		altered[offset] ^= 1;
		reseal(&mut altered);
		compare(&mut reference, &source, 1, &altered, 64 << 30);
	}
	let parsed = crate::tree_patch::ParsedPatch::decode(&bytes, Limits::default()).unwrap();
	let payload = parsed.entries()[1].payload();
	let start = payload.as_ptr() as usize - bytes.as_ptr() as usize;
	for offset in 0..payload.len() {
		let mut altered = bytes.clone();
		altered[start + offset] ^= 0xff;
		reseal(&mut altered);
		compare(&mut reference, &source, 1, &altered, 64 << 30);
	}
}

#[test]
fn missing_sources_wrong_kinds_and_expanded_hardlink_modes_match_native() {
	let mut reference = Reference::start();
	let empty = CanonicalSnapshot::default();
	let rich = fixture(false);
	for (source, selector) in [(&empty, 0), (&rich, 1)] {
		let target = CanonicalSnapshot::new(Snapshot {
			entries: vec![Entry {
				path: Cow::Borrowed(b"app"),
				content: Content::File {
					mode: Mode::from_bits(0o644).unwrap(),
					bytes: Cow::Borrowed(b""),
				},
				metadata: CanonicalMetadata::default(),
			}],
			root: CanonicalMetadata::default(),
		})
		.unwrap();
		let bytes = create(source, &target, CreateOptions::default()).unwrap();
		for operation in [3, 5] {
			let mut changed = bytes.clone();
			changed[120] = operation;
			reseal(&mut changed);
			compare(&mut reference, source, selector, &changed, 64 << 30);
		}
	}
	let mut bytes = reference.call(40, &[4]).unwrap();
	let parsed = crate::tree_patch::ParsedPatch::decode(&bytes, Limits::default()).unwrap();
	let offset = parsed.entries()[5].path().as_ptr() as usize - bytes.as_ptr() as usize - 14;
	bytes[offset] ^= 1;
	reseal(&mut bytes);
	compare(&mut reference, &rich, 1, &bytes, 64 << 30);
}

#[test]
fn apply_borrows_inputs_and_bounds_delta_before_decompression() {
	let mut reference = Reference::start();
	let source = fixture(false);
	let bytes = reference.call(40, &[4]).unwrap();
	let output = apply(&source, &bytes, ApplyLimits::default()).unwrap();
	let rows = &output.snapshot().entries;
	for index in [2, 3, 4] {
		match &rows[index].content {
			Content::File { mode: _, bytes } | Content::Symlink { target: bytes } => {
				assert!(matches!(bytes, Cow::Borrowed(_)))
			}
			Content::Directory { mode: _ } => panic!("fixture must contain file/symlink bytes"),
		}
	}
	assert_eq!(
		rows[4].content.bytes().as_ptr(),
		source.snapshot().entries[3].content.bytes().as_ptr()
	);
	assert_eq!(rows[1].content.bytes(), rows[5].content.bytes());
	assert_ne!(
		rows[1].content.bytes().as_ptr(),
		rows[5].content.bytes().as_ptr()
	);
	let parsed = crate::tree_patch::ParsedPatch::decode(&bytes, Limits::default()).unwrap();
	let offset = parsed.entries()[1].payload().as_ptr() as usize - bytes.as_ptr() as usize;
	let mut hostile = bytes.clone();
	hostile[offset + 77..offset + 85].copy_from_slice(&(1u64 << 30).to_le_bytes());
	reseal(&mut hostile);
	let limits = ApplyLimits {
		max_output_bytes: 6,
		..ApplyLimits::default()
	};
	assert_eq!(apply(&source, &hostile, limits), Err(Error::LimitExceeded));
	hostile[offset + 5] ^= 1;
	reseal(&mut hostile);
	assert_eq!(
		apply(&source, &hostile, limits),
		Err(Error::File(crate::file::Error::SourceHashMismatch))
	);
}
