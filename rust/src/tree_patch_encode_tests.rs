use super::{CreateOptions, Error, Writer, create, project};
use crate::{
	directory::*,
	metadata::tests::Reference,
	metadata::*,
	path_filter::{Action, Rule},
};
use alloc::{borrow::Cow, vec};

fn rich(link: bool) -> CanonicalMetadata<'static> {
	CanonicalMetadata::new(Metadata {
		xattrs: vec![Xattr {
			class: XattrClass::Logical,
			name: Cow::Borrowed(b"x"),
			value: Cow::Borrowed(b"v\0\xff"),
		}],
		aces: vec![Ace {
			tag: AceTag::Owner,
			permissions: Permissions::from_bits(5).unwrap(),
			name: Cow::Borrowed(b""),
		}],
		native_acl: Some(NativeAcl {
			origin: Os::Linux,
			bytes: Cow::Borrowed(b"acl\0\xff"),
		}),
		times: Times {
			mtime: Some(Time { sec: -1, nsec: 7 }),
			..Times::default()
		},
		finder_flags: 1,
		finder_info: Some([0; 32]),
		holes: vec![Hole {
			offset: 0,
			length: 2,
		}],
		hardlink_to: link.then_some(Cow::Borrowed(b"app/base".as_slice())),
	})
	.unwrap()
}
fn root() -> CanonicalMetadata<'static> {
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
fn entry(
	path: &'static [u8],
	content: Content<'static>,
	metadata: CanonicalMetadata<'static>,
) -> Entry<'static> {
	Entry {
		path: Cow::Borrowed(path),
		content,
		metadata,
	}
}
fn file(bytes: &'static [u8]) -> Content<'static> {
	Content::File {
		mode: Mode::from_bits(0o644).unwrap(),
		bytes: Cow::Borrowed(bytes),
	}
}
fn fixture(target: bool) -> CanonicalSnapshot<'static> {
	let mut entries = vec![
		entry(
			b"app",
			Content::Directory {
				mode: Mode::from_bits(0o750).unwrap(),
			},
			CanonicalMetadata::default(),
		),
		entry(
			b"app/base",
			file(if target { b"\0\0NEW\0" } else { b"\0\0OLD\0" }),
			rich(false),
		),
		entry(
			b"app/link",
			Content::Symlink {
				target: Cow::Borrowed(b"base"),
			},
			CanonicalMetadata::default(),
		),
	];
	if target {
		entries.push(entry(
			b"app/new",
			file(b"\0\xffraw"),
			CanonicalMetadata::default(),
		));
	}
	entries.push(entry(
		b"app/same",
		file(b"same"),
		CanonicalMetadata::default(),
	));
	if target {
		entries.push(entry(b"app/z", file(b"\0\0NEW\0"), rich(true)));
	}
	CanonicalSnapshot::new(Snapshot {
		entries,
		root: if target {
			root()
		} else {
			CanonicalMetadata::default()
		},
	})
	.unwrap()
}

#[test]
fn directory_encoding_matches_native_bytes_for_every_omission_mask() {
	let mut reference = Reference::start();
	let source = fixture(false);
	let target = fixture(true);
	let rules = [
		Rule {
			action: Action::Include,
			pattern: "**",
		},
		Rule {
			action: Action::Exclude,
			pattern: "*.tmp",
		},
	];
	for mask in 0..64 {
		let actual = create(
			&source,
			&target,
			CreateOptions {
				rules: &rules,
				omit: Omit::from_bits(mask).unwrap(),
			},
		)
		.unwrap();
		assert_eq!(
			actual,
			reference.call(40, &[4, mask as u8]).unwrap(),
			"mask={mask}"
		);
	}
	for selector in 0..=3 {
		let source = CanonicalSnapshot::default();
		let target = CanonicalSnapshot::new(Snapshot {
			entries: if selector == 2 {
				vec![entry(
					b"x",
					Content::File {
						mode: Mode::from_bits(0o640).unwrap(),
						bytes: Cow::Borrowed(b"\0\xffbody"),
					},
					CanonicalMetadata::default(),
				)]
			} else {
				vec![]
			},
			root: if selector == 1 {
				root()
			} else {
				CanonicalMetadata::default()
			},
		})
		.unwrap();
		let rules = [Rule {
			action: Action::Include,
			pattern: "**",
		}];
		let actual = create(
			&source,
			&target,
			CreateOptions {
				rules: if selector == 3 { &rules } else { &[] },
				omit: Omit::from_bits(if selector == 0 { 63 } else { 0 }).unwrap(),
			},
		)
		.unwrap();
		assert_eq!(actual, reference.call(40, &[selector]).unwrap());
	}
}

#[test]
fn metadata_projection_borrows_retained_buffers_and_preserves_canonical_bytes() {
	let original = rich(true);
	for mask in 0..64 {
		let omit = Omit::from_bits(mask).unwrap();
		let projected = original.borrowing_omitting(omit).unwrap();
		let normalized = CanonicalMetadata::normalize(rich(true).into_metadata(), omit).unwrap();
		assert_eq!(projected, normalized);
		assert_eq!(projected.encode().unwrap(), normalized.encode().unwrap());
		let value = projected.metadata();
		for attr in &value.xattrs {
			assert!(
				matches!(attr.name, Cow::Borrowed(_)) && matches!(attr.value, Cow::Borrowed(_))
			);
			assert_eq!(
				attr.value.as_ptr(),
				original.metadata().xattrs[0].value.as_ptr()
			);
		}
		assert!(
			value
				.aces
				.iter()
				.all(|ace| matches!(ace.name, Cow::Borrowed(_)))
		);
		if let Some(acl) = &value.native_acl {
			assert!(matches!(acl.bytes, Cow::Borrowed(_)));
		}
		if let Some(path) = &value.hardlink_to {
			assert!(matches!(path, Cow::Borrowed(_)));
		}
	}
}

#[test]
fn kind_changes_and_source_root_identity_match_native() {
	let source = CanonicalSnapshot::new(Snapshot {
		entries: vec![
			entry(
				b"x",
				Content::Directory {
					mode: Mode::from_bits(0o700).unwrap(),
				},
				CanonicalMetadata::default(),
			),
			entry(
				b"y",
				Content::File {
					mode: Mode::from_bits(0o640).unwrap(),
					bytes: Cow::Borrowed(b"old"),
				},
				CanonicalMetadata::default(),
			),
		],
		root: CanonicalMetadata::new(Metadata {
			times: Times {
				mtime: Some(Time { sec: -1, nsec: 7 }),
				..Times::default()
			},
			..Metadata::default()
		})
		.unwrap(),
	})
	.unwrap();
	let target = CanonicalSnapshot::new(Snapshot {
		entries: vec![
			entry(b"x", file(b"new\0\xff"), CanonicalMetadata::default()),
			entry(
				b"y",
				Content::Symlink {
					target: Cow::Borrowed(b"x"),
				},
				CanonicalMetadata::default(),
			),
		],
		root: CanonicalMetadata::default(),
	})
	.unwrap();
	let mut reference = Reference::start();
	assert_eq!(
		create(&source, &target, CreateOptions::default()).unwrap(),
		reference.call(40, &[5]).unwrap()
	);
}

#[test]
fn encoding_limits_precede_output_growth_and_projection_borrows_file_data() {
	let snapshot = fixture(true);
	let projected = project(&snapshot, Omit::from_bits(1).unwrap()).unwrap();
	for (old, new) in snapshot
		.snapshot()
		.entries
		.iter()
		.zip(&projected.snapshot().entries)
	{
		assert_eq!(old.content.bytes().as_ptr(), new.content.bytes().as_ptr());
		assert!(matches!(new.path, Cow::Borrowed(_)));
	}
	let empty = CanonicalSnapshot::default();
	let rules = [Rule {
		action: Action::Include,
		pattern: "",
	}];
	assert_eq!(
		create(
			&empty,
			&empty,
			CreateOptions {
				rules: &rules,
				omit: Omit::default()
			}
		),
		Err(Error::Filter(crate::path_filter::Error::EmptyPattern))
	);
	let pattern = alloc::string::String::from_iter(core::iter::repeat_n('a', 4097));
	let rule = Rule {
		action: Action::Include,
		pattern: &pattern,
	};
	assert_eq!(
		create(
			&empty,
			&empty,
			CreateOptions {
				rules: &[rule],
				omit: Omit::default()
			}
		),
		Err(Error::LimitExceeded)
	);
	let too_many = vec![rule; 4097];
	assert_eq!(
		create(
			&empty,
			&empty,
			CreateOptions {
				rules: &too_many,
				omit: Omit::default()
			}
		),
		Err(Error::LimitExceeded)
	);
	let mut output = Writer {
		bytes: vec![],
		maximum: 3,
	};
	output.put(b"abc").unwrap();
	let capacity = output.bytes.capacity();
	assert_eq!(output.put(b"d"), Err(Error::LimitExceeded));
	assert_eq!(output.bytes, b"abc");
	assert_eq!(output.bytes.capacity(), capacity);
}
