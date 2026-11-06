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
