use super::{Reference, compare};
use crate::metadata::*;
use alloc::borrow::Cow;

fn fixture(selector: u8) -> Result<Metadata<'static>, Error> {
	if selector > 31 {
		return Err(Error::BadMetadata);
	}
	if selector == 0 {
		return Ok(Metadata::default());
	}
	let mut info = [0; 32];
	for (index, byte) in info.iter_mut().enumerate() {
		*byte = index as u8;
	}
	let mut value = Metadata {
		xattrs: vec![
			Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"app"),
				value: Cow::Borrowed(b"v\0\xff"),
			},
			Xattr {
				class: XattrClass::Raw,
				name: Cow::Borrowed(b"system.meta"),
				value: Cow::Borrowed(b"\x01raw"),
			},
		],
		aces: vec![
			Ace {
				tag: AceTag::Owner,
				permissions: Permissions::from_bits(3).unwrap(),
				name: Cow::Borrowed(b""),
			},
			Ace {
				tag: AceTag::NamedUser,
				permissions: Permissions::from_bits(5).unwrap(),
				name: Cow::Borrowed(b"alice"),
			},
		],
		native_acl: Some(NativeAcl {
			origin: match selector {
				2 => Os::Macos,
				3 => Os::Mswin,
				_ => Os::Linux,
			},
			bytes: Cow::Borrowed(b"\0\xffacl"),
		}),
		times: Times {
			mtime: Some(Time { sec: -1, nsec: 7 }),
			atime: Some(Time { sec: 0, nsec: 0 }),
			btime: Some(Time {
				sec: i64::MAX,
				nsec: 999_999_999,
			}),
		},
		finder_flags: 0x1234,
		finder_info: Some(info),
		holes: vec![
			Hole {
				offset: 0,
				length: 16,
			},
			Hole {
				offset: 32,
				length: 32,
			},
		],
		hardlink_to: Some(Cow::Borrowed(b"dir/base")),
	};
	match selector {
		1..=3 => {}
		4 => {
			value.xattrs[1].class = value.xattrs[0].class;
			value.xattrs[1].name = Cow::Borrowed(b"app");
			value.xattrs[1].value = Cow::Borrowed(b"v\0\xff");
		}
		5 => {
			value.xattrs[0].class = XattrClass::Raw;
			value.xattrs[1].class = XattrClass::Logical;
		}
		6 => value.xattrs[0].name = Cow::Borrowed(b""),
		7 => value.xattrs[0].name = Cow::Borrowed(b"user.difz.btime"),
		8 => value.xattrs[1].name = Cow::Borrowed(b"binary\xff"),
		9 => value.xattrs[1].name = Cow::Borrowed(b"bad/name"),
		10 => {
			value.aces[1].tag = AceTag::Owner;
			value.aces[1].name = Cow::Borrowed(b"");
			value.aces[1].permissions = Permissions::from_bits(3).unwrap();
		}
		11 => {
			value.aces[0].tag = AceTag::NamedUser;
			value.aces[0].name = Cow::Borrowed(b"alice");
			value.aces[1].tag = AceTag::Owner;
			value.aces[1].name = Cow::Borrowed(b"");
		}
		12 => value.aces[1].name = Cow::Borrowed(b""),
		13 => value.native_acl.as_mut().unwrap().bytes = Cow::Borrowed(b""),
		14 => value.times.mtime.as_mut().unwrap().nsec = 1_000_000_000,
		15 => value.holes[0].length = 0,
		16 => {
			value.holes[1].offset = u64::MAX;
			value.holes[1].length = 1;
		}
		17 => {
			value.holes[1].offset = 16;
			value.holes[1].length = 16;
		}
		18 => value.holes[1].offset = 8,
		19 => {
			value.holes[0].offset = 32;
			value.holes[1].offset = 0;
		}
		20 => value.hardlink_to = Some(Cow::Borrowed(b"../escape")),
		21 => value.times = Times::default(),
		22 => value.finder_info = Some([0; 32]),
		23 => value.hardlink_to = None,
		24 => value.holes.clear(),
		25 => value.native_acl.as_mut().unwrap().origin = Os::Mswin,
		26 => {
			value.times.mtime = Some(Time {
				sec: i64::MIN,
				nsec: 999_999_999,
			})
		}
		27 => value.xattrs.clear(),
		28 => value.aces.clear(),
		29 => value.native_acl = None,
		30 => {
			value.finder_info = None;
			value.finder_flags = 0;
		}
		31 => {
			value.holes[1].offset = u64::MAX - 7;
			value.holes[1].length = 7;
		}
		_ => unreachable!(),
	}
	Ok(value)
}

fn normalization_fixture(selector: u8) -> Metadata<'static> {
	if selector <= 31 {
		return fixture(selector).unwrap();
	}
	let mut value = fixture(1).unwrap();
	match selector {
		32 | 33 => {
			value.xattrs[1] = Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"app"),
				value: Cow::Borrowed(b"v\0\xff"),
			};
			if selector == 32 {
				value.aces[1].name = Cow::Borrowed(b"");
				value.native_acl.as_mut().unwrap().bytes = Cow::Borrowed(b"");
				value.times.mtime.as_mut().unwrap().nsec = 1_000_000_000;
				value.holes[0].length = 0;
				value.hardlink_to = Some(Cow::Borrowed(b"../escape"));
			} else {
				value.xattrs[0].name = Cow::Borrowed(b"");
				value.aces[1] = Ace {
					tag: AceTag::Owner,
					permissions: Permissions::from_bits(3).unwrap(),
					name: Cow::Borrowed(b""),
				};
			}
		}
		34 => {
			value.native_acl.as_mut().unwrap().bytes = Cow::Borrowed(b"");
			value.times.mtime.as_mut().unwrap().nsec = 1_000_000_000;
			value.holes[0].length = 0;
		}
		_ => unreachable!(),
	}
	value
}

#[test]
fn canonical_wire_and_hash_match_independent_native_fixtures_and_rejections() {
	let mut reference = Reference::start();
	for selector in 0..=255u8 {
		compare(
			&mut reference,
			fixture(selector).and_then(CanonicalMetadata::new),
			12,
			&[selector],
			|c| c.encode().unwrap(),
		);
		compare(
			&mut reference,
			fixture(selector).and_then(CanonicalMetadata::new),
			13,
			&[selector],
			|c| c.hash().to_vec(),
		);
	}
}

#[test]
fn canonical_identity_binds_origin_presence_and_each_metadata_family() {
	let mut reference = Reference::start();
	let empty = CanonicalMetadata::default();
	assert_eq!(empty.encode().unwrap(), vec![0; 20]);
	assert_eq!(empty.hash().to_vec(), reference.call(13, &[0]).unwrap());
	let baseline = CanonicalMetadata::new(fixture(1).unwrap()).unwrap();
	assert_eq!(baseline.metadata(), &fixture(1).unwrap());
	for selector in [2, 3, 8, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31] {
		let changed = CanonicalMetadata::new(fixture(selector).unwrap()).unwrap();
		assert_ne!(baseline.hash(), changed.hash(), "selector={selector}");
	}
}

fn check_borrowed(value: &Cow<'_, [u8]>, input: &[u8]) {
	assert!(matches!(value, Cow::Borrowed(_)));
	// Empty views have no byte location to preserve.
	if value.is_empty() {
		return;
	}
	let start = input.as_ptr() as usize;
	let pointer = value.as_ptr() as usize;
	assert!(pointer >= start && pointer + value.len() <= start + input.len());
}

#[test]
fn canonical_decoder_borrows_native_records_and_preserves_wire_identity() {
	let mut reference = Reference::start();
	for selector in 0..=31u8 {
		let Ok(bytes) = reference.call(12, &[selector]) else {
			continue;
		};
		let original = bytes.clone();
		let decoded = CanonicalMetadata::decode(&bytes).unwrap();
		assert_eq!(decoded.metadata(), &fixture(selector).unwrap());
		assert_eq!(decoded.encode().unwrap(), bytes);
		assert_eq!(decoded.hash().to_vec(), reference.call(15, &bytes).unwrap());
		for attr in &decoded.metadata().xattrs {
			check_borrowed(&attr.name, &bytes);
			check_borrowed(&attr.value, &bytes);
		}
		for ace in &decoded.metadata().aces {
			check_borrowed(&ace.name, &bytes);
		}
		if let Some(acl) = &decoded.metadata().native_acl {
			check_borrowed(&acl.bytes, &bytes);
		}
		if let Some(path) = &decoded.metadata().hardlink_to {
			check_borrowed(path, &bytes);
		}
		assert_eq!(bytes, original);
	}
}

#[test]
fn canonical_decoder_matches_native_truncations_mutations_and_reserved_fields() {
	let mut reference = Reference::start();
	for selector in [0, 1, 2, 3, 8, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31] {
		let bytes = reference.call(12, &[selector]).unwrap();
		for length in 0..bytes.len() {
			compare(
				&mut reference,
				CanonicalMetadata::decode(&bytes[..length]),
				14,
				&bytes[..length],
				|m| m.encode().unwrap(),
			);
		}
		let mut trailing = bytes.clone();
		trailing.push(0);
		compare(
			&mut reference,
			CanonicalMetadata::decode(&trailing),
			14,
			&trailing,
			|m| m.encode().unwrap(),
		);
	}
	let bytes = reference.call(12, &[1]).unwrap();
	for index in 0..bytes.len() {
		for bit in 0..8 {
			let mut changed = bytes.clone();
			changed[index] ^= 1 << bit;
			compare(
				&mut reference,
				CanonicalMetadata::decode(&changed),
				14,
				&changed,
				|m| m.encode().unwrap(),
			);
		}
	}
	for count in [1u32, u32::MAX] {
		assert_eq!(
			CanonicalMetadata::decode(&count.to_le_bytes()),
			Err(Error::TruncatedMetadata)
		);
	}
}

#[test]
fn canonical_decoder_covers_every_tag_permission_and_presence_byte() {
	let mut reference = Reference::start();
	let empty = reference.call(12, &[0]).unwrap();
	// Minimal records use the published field layout, independent of Rust encoding.
	let mut attr = 1u32.to_le_bytes().to_vec();
	attr.push(1);
	attr.extend(1u32.to_le_bytes());
	attr.push(b'x');
	attr.extend(0u32.to_le_bytes());
	attr.extend(&empty[4..]);
	let mut ace = empty[..4].to_vec();
	ace.extend(1u32.to_le_bytes());
	ace.extend([1, 0]);
	ace.extend(0u32.to_le_bytes());
	ace.extend(&empty[8..]);
	for byte in 0..=255u8 {
		for (template, offset) in [
			(&empty, 8),
			(&empty, 9),
			(&empty, 14),
			(&empty, 19),
			(&attr, 4),
			(&ace, 8),
			(&ace, 9),
		] {
			let mut bytes = template.clone();
			bytes[offset] = byte;
			compare(
				&mut reference,
				CanonicalMetadata::decode(&bytes),
				14,
				&bytes,
				|m| m.encode().unwrap(),
			);
		}
	}
}

#[test]
fn normalization_matches_native_for_every_omission_mask_and_family_error() {
	let mut reference = Reference::start();
	let mut hash_reference = Reference::start();
	for selector in 0..=34u8 {
		for mask in 0..64u8 {
			let normalized = CanonicalMetadata::normalize(
				normalization_fixture(selector),
				Omit::from_bits(u32::from(mask)).unwrap(),
			);
			compare(&mut reference, normalized, 16, &[selector, mask], |m| {
				let wire = m.encode().unwrap();
				assert_eq!(
					hash_reference.call(17, &[selector, mask]).unwrap(),
					m.hash().to_vec()
				);
				let again =
					CanonicalMetadata::normalize(m.into_metadata(), Omit::default()).unwrap();
				assert_eq!(again.encode().unwrap(), wire);
				wire
			});
		}
	}
}

#[test]
fn normalization_merges_native_extent_permutations_and_keeps_owned_buffers() {
	let mut reference = Reference::start();
	let ranges = [(0, 4), (2, 1), (4, 8), (12, 1), (99, 1), (u64::MAX - 5, 5)];
	for reverse in [false, true] {
		for shift in 0..ranges.len() {
			let mut holes: Vec<Hole> = ranges
				.iter()
				.map(|&(offset, length)| Hole { offset, length })
				.collect();
			holes.rotate_left(shift);
			if reverse {
				holes.reverse();
			}
			let mut wire = Vec::new();
			for hole in &holes {
				wire.extend(hole.offset.to_le_bytes());
				wire.extend(hole.length.to_le_bytes());
			}
			let normalized = CanonicalMetadata::normalize(
				Metadata {
					holes,
					..Metadata::default()
				},
				Omit::default(),
			)
			.unwrap();
			assert_eq!(
				normalized.encode().unwrap(),
				reference.call(18, &wire).unwrap()
			);
			assert_eq!(
				normalized.metadata().holes,
				vec![
					Hole {
						offset: 0,
						length: 13
					},
					Hole {
						offset: 99,
						length: 1
					},
					Hole {
						offset: u64::MAX - 5,
						length: 5
					}
				]
			);
		}
	}
	let mut raw = fixture(1).unwrap();
	raw.xattrs[0].value = Cow::Owned(vec![0, 255, 42]);
	let pointer = raw.xattrs[0].value.as_ptr();
	raw.xattrs.reverse();
	raw.aces.reverse();
	let normalized = CanonicalMetadata::normalize(raw, Omit::default()).unwrap();
	assert_eq!(normalized.metadata().xattrs[0].value.as_ptr(), pointer);
	assert!(matches!(
		normalized.metadata().xattrs[0].value,
		Cow::Owned(_)
	));
}
