use super::*;
use crate::metadata::{
	Ace, AceTag, CanonicalMetadata, Hole, Metadata, NativeAcl, Os, Permissions, Time, Times, Xattr,
	XattrClass, tests::Reference,
};
use alloc::borrow::Cow;

fn file_meta(link: Option<&'static [u8]>) -> CanonicalMetadata<'static> {
	CanonicalMetadata::new(Metadata {
		xattrs: vec![Xattr {
			class: XattrClass::Logical,
			name: Cow::Borrowed(b"x"),
			value: Cow::Borrowed(b"v\0\xff"),
		}],
		times: Times {
			mtime: Some(Time { sec: -1, nsec: 7 }),
			..Times::default()
		},
		holes: vec![Hole {
			offset: 0,
			length: 2,
		}],
		hardlink_to: link.map(Cow::Borrowed),
		..Metadata::default()
	})
	.unwrap()
}
fn root_meta() -> CanonicalMetadata<'static> {
	CanonicalMetadata::new(Metadata {
		xattrs: vec![Xattr {
			class: XattrClass::Logical,
			name: Cow::Borrowed(b"root"),
			value: Cow::Borrowed(b"\0\xff"),
		}],
		..Metadata::default()
	})
	.unwrap()
}
fn change_meta(entry: &mut Entry<'static>, change: impl FnOnce(&mut Metadata<'static>)) {
	let mut raw = core::mem::take(&mut entry.metadata).into_metadata();
	change(&mut raw);
	entry.metadata = CanonicalMetadata::new(raw).unwrap();
}
pub(super) fn fixture(selector: u8) -> Snapshot<'static> {
	if selector == 0 {
		return Snapshot::default();
	}
	if selector == 26 || selector == 27 {
		let count = if selector == 26 { 1_000_001 } else { 1_000_000 };
		return Snapshot {
			entries: (0..count)
				.map(|_| Entry {
					path: Cow::Borrowed(b"x"),
					content: Content::File {
						mode: Mode::from_bits(0o644).unwrap(),
						bytes: Cow::Borrowed(b""),
					},
					metadata: CanonicalMetadata::default(),
				})
				.collect(),
			root: CanonicalMetadata::default(),
		};
	}
	if (29..=32).contains(&selector) {
		let mode = Mode::from_bits(if selector <= 30 { 0o750 } else { 0o777 }).unwrap();
		let file = || Content::File {
			mode,
			bytes: Cow::Borrowed(if selector <= 30 { b"" } else { b"file" }),
		};
		let (first, second) = match selector {
			29 => (Content::Directory { mode }, file()),
			30 => (file(), Content::Directory { mode }),
			31 => (
				file(),
				Content::Symlink {
					target: Cow::Borrowed(b"file"),
				},
			),
			32 => (
				Content::Symlink {
					target: Cow::Borrowed(b"file"),
				},
				file(),
			),
			_ => unreachable!(),
		};
		let metadata = CanonicalMetadata::new(Metadata {
			hardlink_to: Some(Cow::Borrowed(b"a")),
			..Metadata::default()
		})
		.unwrap();
		return Snapshot {
			entries: vec![
				Entry {
					path: Cow::Borrowed(b"a"),
					content: first,
					metadata: CanonicalMetadata::default(),
				},
				Entry {
					path: Cow::Borrowed(b"b"),
					content: second,
					metadata,
				},
			],
			root: CanonicalMetadata::default(),
		};
	}
	let mut snapshot = Snapshot {
		entries: vec![
			Entry {
				path: Cow::Borrowed(b"a"),
				content: Content::Directory {
					mode: Mode::from_bits(0o750).unwrap(),
				},
				metadata: CanonicalMetadata::default(),
			},
			Entry {
				path: Cow::Borrowed(b"a/base"),
				content: Content::File {
					mode: Mode::from_bits(0o644).unwrap(),
					bytes: Cow::Borrowed(b"\0\0X\0"),
				},
				metadata: file_meta(None),
			},
			Entry {
				path: Cow::Borrowed(b"a/link"),
				content: Content::Symlink {
					target: Cow::Borrowed(b"base"),
				},
				metadata: CanonicalMetadata::default(),
			},
			Entry {
				path: Cow::Borrowed(b"a/z"),
				content: Content::File {
					mode: Mode::from_bits(0o644).unwrap(),
					bytes: Cow::Borrowed(b"\0\0X\0"),
				},
				metadata: file_meta(Some(b"a/base")),
			},
		],
		root: CanonicalMetadata::default(),
	};
	match selector {
		1 => {}
		2 => snapshot.root = root_meta(),
		3 => {
			snapshot.entries.clear();
			snapshot.root = root_meta();
		}
		4 => snapshot.entries[0].path = Cow::Borrowed(b"../escape"),
		5 => snapshot.entries.swap(1, 2),
		6 | 22 | 40 | 41 => snapshot.entries[2].path = Cow::Borrowed(b"a/base"),
		7 => snapshot.entries[0].path = Cow::Borrowed(b"0"),
		8 => {
			snapshot.entries[0].content = Content::File {
				mode: Mode::from_bits(0o750).unwrap(),
				bytes: Cow::Borrowed(b""),
			}
		}
		9 => {
			snapshot.entries[2].content = Content::Symlink {
				target: Cow::Borrowed(b""),
			}
		}
		10 => {
			snapshot.entries[2].content = Content::Symlink {
				target: Cow::Borrowed(b"../../escape"),
			}
		}
		11 | 12 => change_meta(&mut snapshot.entries[1], |m| {
			m.holes = vec![Hole {
				offset: if selector == 11 { 2 } else { 4 },
				length: 1,
			}]
		}),
		13 => change_meta(&mut snapshot.entries[0], |m| {
			m.holes = vec![Hole {
				offset: 0,
				length: 1,
			}]
		}),
		14 | 23 => change_meta(&mut snapshot.entries[3], |m| {
			m.hardlink_to = Some(Cow::Borrowed(b"a/missing"))
		}),
		15 => change_meta(&mut snapshot.entries[3], |m| {
			m.hardlink_to = Some(Cow::Borrowed(b"a/z"))
		}),
		16 => change_meta(&mut snapshot.entries[1], |m| {
			m.hardlink_to = Some(Cow::Borrowed(b"a/z"))
		}),
		17 => {
			snapshot.entries[3].content = Content::File {
				mode: Mode::from_bits(0o600).unwrap(),
				bytes: Cow::Borrowed(b"\0\0X\0"),
			}
		}
		18 => {
			snapshot.entries[3].content = Content::File {
				mode: Mode::from_bits(0o644).unwrap(),
				bytes: Cow::Borrowed(b"\0\0Y\0"),
			}
		}
		19 => change_meta(&mut snapshot.entries[3], |m| {
			m.times.mtime.as_mut().unwrap().sec = 1
		}),
		20 => {}
		21 | 28 => {
			snapshot.root = CanonicalMetadata::new(Metadata {
				hardlink_to: Some(Cow::Borrowed(b"a/base")),
				..Metadata::default()
			})
			.unwrap()
		}
		24 => change_meta(&mut snapshot.entries[3], |m| m.hardlink_to = None),
		25 => snapshot.entries.push(Entry {
			path: Cow::Borrowed(b"a/zz"),
			content: Content::File {
				mode: Mode::from_bits(0o644).unwrap(),
				bytes: Cow::Borrowed(b"\0\0X\0"),
			},
			metadata: file_meta(Some(b"a/z")),
		}),
		33 => change_meta(&mut snapshot.entries[3], |m| {
			m.xattrs[0].value = Cow::Borrowed(b"different")
		}),
		34 => change_meta(&mut snapshot.entries[3], |m| {
			m.aces = vec![Ace {
				tag: AceTag::Owner,
				permissions: Permissions::READ,
				name: Cow::Borrowed(b""),
			}]
		}),
		35 => change_meta(&mut snapshot.entries[3], |m| {
			m.native_acl = Some(NativeAcl {
				origin: Os::Linux,
				bytes: Cow::Borrowed(b"\0\xff"),
			})
		}),
		36 => change_meta(&mut snapshot.entries[3], |m| {
			m.times.atime = Some(Time { sec: 0, nsec: 0 })
		}),
		37 => change_meta(&mut snapshot.entries[3], |m| m.finder_flags = 1),
		38 => change_meta(&mut snapshot.entries[3], |m| m.finder_info = Some([0; 32])),
		39 => change_meta(&mut snapshot.entries[3], |m| m.holes[0].length = 1),
		_ => unreachable!(),
	}
	if selector == 20 || selector == 23 || selector == 28 {
		let mut root = core::mem::take(&mut snapshot.root).into_metadata();
		root.holes = vec![Hole {
			offset: 0,
			length: 1,
		}];
		snapshot.root = CanonicalMetadata::new(root).unwrap();
	}
	if selector == 22 {
		change_meta(&mut snapshot.entries[0], |m| {
			m.holes = vec![Hole {
				offset: 0,
				length: 1,
			}]
		});
	}
	if selector == 40 {
		snapshot.entries[3].path = Cow::Borrowed(b"../escape");
	}
	if selector == 41 {
		snapshot.entries[2].content = Content::Symlink {
			target: Cow::Borrowed(b"/outside"),
		};
	}
	snapshot
}

#[test]
fn canonical_snapshots_match_native_hierarchy_relations_identity_and_count_boundaries() {
	let mut reference = Reference::start();
	for selector in 0..=41 {
		let actual = CanonicalSnapshot::new(fixture(selector))
			.map(|s| s.hash().to_vec())
			.map_err(|e| format!("{e:?}"));
		assert_eq!(
			actual,
			reference.call(34, &[selector]),
			"selector={selector}"
		);
	}
}

#[test]
fn canonical_snapshot_identity_preserves_borrows_and_binds_root_and_hardlink_presence() {
	let mut reference = Reference::start();
	let empty = CanonicalSnapshot::default();
	assert_eq!(empty.hash().to_vec(), reference.call(34, &[0]).unwrap());
	let baseline = CanonicalSnapshot::new(fixture(1)).unwrap();
	for selector in [0, 2, 3, 24] {
		let changed = CanonicalSnapshot::new(fixture(selector)).unwrap();
		assert_ne!(baseline.hash(), changed.hash());
	}
	assert!(matches!(
		baseline.snapshot().entries[1].content,
		Content::File {
			bytes: Cow::Borrowed(_),
			..
		}
	));
	let pointer = baseline.snapshot().entries[1].content.bytes().as_ptr();
	let raw = baseline.into_snapshot();
	let again = CanonicalSnapshot::new(raw).unwrap();
	assert_eq!(
		again.snapshot().entries[1].content.bytes().as_ptr(),
		pointer
	);
}
