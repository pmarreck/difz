use super::*;
use crate::metadata::{
	CanonicalMetadata, Metadata, Time, Times, Xattr, XattrClass, tests::Reference,
};
use alloc::{borrow::Cow, vec::Vec};

#[test]
fn portable_modes_match_native_validation_for_every_u16_value() {
	let mut reference = Reference::start();
	for bits in 0..=u16::MAX {
		let actual = Mode::from_bits(bits)
			.map(|mode| mode.bits().to_le_bytes().to_vec())
			.map_err(|e| format!("{e:?}"));
		assert_eq!(
			actual,
			reference.call(32, &bits.to_le_bytes()),
			"bits={bits}"
		);
	}
}

// Independent client serialization checks the record's exposed views against
// native tree identity. This does not grant raw snapshots canonical status.
fn identity_from_views(snapshot: &Snapshot<'_>) -> [u8; 32] {
	let Snapshot { entries, root } = snapshot;
	let mut hash = blake3::Hasher::new();
	hash.update(b"DIFZTREE-ID\x02");
	hash.update(&(entries.len() as u32).to_le_bytes());
	for Entry {
		path,
		content,
		metadata,
	} in entries
	{
		hash.update(&[content.kind_tag()]);
		hash.update(&content.mode().bits().to_le_bytes());
		hash.update(&(path.len() as u32).to_le_bytes());
		hash.update(path);
		hash.update(&(content.bytes().len() as u64).to_le_bytes());
		hash.update(content.bytes());
		hash.update(&metadata.hash());
	}
	if !root.metadata().is_empty() {
		hash.update(b"DIFZTREE-ROOT\x01");
		hash.update(&root.hash());
	}
	*hash.finalize().as_bytes()
}

#[test]
fn snapshot_record_views_match_native_kinds_bytes_modes_and_metadata_identity() {
	let mut reference = Reference::start();
	let empty = Snapshot::default();
	assert_eq!(empty.entries.capacity(), 0);
	assert!(empty.root.metadata().is_empty());
	assert_eq!(
		identity_from_views(&empty).to_vec(),
		reference.call(33, &[0]).unwrap()
	);
	for selector in 1..=4 {
		let (path, content) = match selector {
			1 => (
				b"dir".as_slice(),
				Content::Directory {
					mode: Mode::from_bits(0o750).unwrap(),
				},
			),
			2 | 4 => (
				b"file".as_slice(),
				Content::File {
					mode: Mode::from_bits(0o644).unwrap(),
					bytes: Cow::Borrowed(b"\0\xff"),
				},
			),
			3 => (
				b"link".as_slice(),
				Content::Symlink {
					target: Cow::Borrowed(b"file"),
				},
			),
			_ => unreachable!(),
		};
		let mut snapshot = Snapshot {
			entries: vec![Entry {
				path: Cow::Borrowed(path),
				content,
				metadata: CanonicalMetadata::default(),
			}],
			root: CanonicalMetadata::default(),
		};
		if selector == 4 {
			snapshot.entries[0].metadata = CanonicalMetadata::new(Metadata {
				times: Times {
					mtime: Some(Time { sec: -1, nsec: 7 }),
					..Times::default()
				},
				..Metadata::default()
			})
			.unwrap();
			snapshot.root = CanonicalMetadata::new(Metadata {
				xattrs: vec![Xattr {
					class: XattrClass::Logical,
					name: Cow::Borrowed(b"x"),
					value: Cow::Borrowed(b"\0\xff"),
				}],
				..Metadata::default()
			})
			.unwrap();
		}
		assert_eq!(
			identity_from_views(&snapshot).to_vec(),
			reference.call(33, &[selector]).unwrap()
		);
	}
	let owned = vec![0, 255, 42];
	let pointer = owned.as_ptr();
	let content = Content::File {
		mode: Mode::from_bits(0o600).unwrap(),
		bytes: Cow::Owned(owned),
	};
	assert_eq!(content.bytes().as_ptr(), pointer);
	assert_eq!(content.bytes(), [0, 255, 42]);
	let borrowed = b"target";
	let content = Content::Symlink {
		target: Cow::Borrowed(borrowed),
	};
	assert_eq!(content.bytes().as_ptr(), borrowed.as_ptr());
}
