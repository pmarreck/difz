use super::*;
use crate::metadata::{tests::Reference, *};
use alloc::{format, string::String, vec};

fn native_error(error: super::Error) -> String {
	match error {
		super::Error::Metadata(error) => format!("{error:?}"),
		other => format!("{other:?}"),
	}
}
fn fixture(absent: u8, flags: u8) -> Record<'static> {
	let time = Time { sec: -1, nsec: 7 };
	Record {
		name: Cow::Borrowed(b"a"),
		absent_times: absent,
		observed_mtime: (flags & 8 != 0).then_some(Time { sec: 42, nsec: 0 }),
		acl_override: flags & 16 != 0,
		finder_override: flags & 32 != 0,
		metadata: CanonicalMetadata::new(Metadata {
			xattrs: if flags & 64 != 0 {
				vec![Xattr {
					class: XattrClass::Logical,
					name: Cow::Borrowed(b"x"),
					value: Cow::Borrowed(b"\0\xff"),
				}]
			} else {
				vec![]
			},
			times: Times {
				mtime: (flags & 1 != 0).then_some(time),
				atime: (flags & 2 != 0).then_some(time),
				btime: (flags & 4 != 0).then_some(time),
			},
			..Metadata::default()
		})
		.unwrap(),
	}
}
#[test]
fn all_presence_absence_and_override_combinations_match_native_encoding() {
	let mut reference = Reference::start();
	assert_eq!(
		Transport::new(vec![]).unwrap().encode().unwrap(),
		reference.call(46, &[0]).unwrap()
	);
	for absent in [0, 1, 2, 3, 4, 5, 6, 7, 8, 128, 255] {
		for flags in 0..128 {
			let actual = Transport::new(vec![fixture(absent, flags)])
				.and_then(|v| v.encode())
				.map_err(native_error);
			assert_eq!(
				actual,
				reference.call(46, &[1, absent, flags]),
				"absent={absent} flags={flags}"
			);
		}
	}
}
#[test]
fn borrowed_transport_decoding_and_malformed_inputs_match_native() {
	let mut reference = Reference::start();
	for request in [
		&[0][..],
		&[1, 0, 64],
		&[1, 5, 8],
		&[1, 0, 16],
		&[1, 0, 32],
		&[1, 0, 127],
		&[2],
	] {
		let bytes = reference.call(46, request).unwrap();
		let decoded = Transport::decode(&bytes).unwrap();
		assert_eq!(decoded.encode().unwrap(), bytes);
		for record in decoded.records() {
			assert!(matches!(record.name, Cow::Borrowed(_)));
			assert!(decoded.find(&record.name).is_some());
		}
		assert!(decoded.find(b"missing").is_none());
		let mut cases: Vec<Vec<u8>> = (0..bytes.len()).map(|n| bytes[..n].to_vec()).collect();
		for offset in 0..bytes.len() {
			let mut changed = bytes.clone();
			changed[offset] ^= 0xff;
			cases.push(changed);
		}
		let mut extra = bytes.clone();
		extra.push(0);
		cases.push(extra);
		for changed in cases {
			let actual = Transport::decode(&changed)
				.and_then(|v| v.encode())
				.map_err(native_error);
			assert_eq!(actual, reference.call(47, &changed), "bytes={changed:?}");
		}
	}
	let too_large = vec![0; MAX_BYTES + 1];
	let actual = Transport::decode(&too_large)
		.and_then(|v| v.encode())
		.map_err(native_error);
	assert_eq!(actual, reference.call(47, &too_large));
}

#[test]
fn native_basename_count_and_exact_transport_byte_boundaries() {
	let mut reference = Reference::start();
	for name in [
		b"".as_slice(),
		b"a",
		b".",
		b"..",
		b"a/b",
		b"a\\b",
		b"a\0b",
		b"\xff",
		b"C:drive",
		"é".as_bytes(),
		&vec![b'a'; 4097],
	] {
		let mut record = fixture(0, 64);
		record.name = Cow::Owned(name.to_vec());
		let mut request = vec![3];
		request.extend_from_slice(name);
		let actual = Transport::new(vec![record])
			.and_then(|v| v.encode())
			.map_err(native_error);
		assert_eq!(actual, reference.call(46, &request));
	}
	for count in [65470u32, 65481, 65482, 65483, 65536] {
		let metadata = CanonicalMetadata::new(Metadata {
			xattrs: vec![Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"x"),
				value: Cow::Owned(vec![0; count as usize]),
			}],
			..Metadata::default()
		})
		.unwrap();
		let mut record = fixture(0, 64);
		record.metadata = metadata;
		let mut request = vec![4];
		request.extend_from_slice(&count.to_le_bytes());
		let actual = Transport::new(vec![record])
			.and_then(|v| v.encode())
			.map_err(native_error);
		assert_eq!(actual, reference.call(46, &request), "value length={count}");
	}
	for count in [0u32, 1, 2, 2113, 2114] {
		let records = (0..count).map(|_| fixture(0, 64)).collect();
		let mut request = vec![5];
		request.extend_from_slice(&count.to_le_bytes());
		let actual = Transport::new(records)
			.and_then(|v| v.encode())
			.map_err(native_error);
		assert_eq!(actual, reference.call(46, &request), "record count={count}");
	}
	for selector in 0..3 {
		let metadata = CanonicalMetadata::new(Metadata {
			holes: if selector == 0 {
				vec![Hole {
					offset: 0,
					length: 1,
				}]
			} else {
				vec![]
			},
			hardlink_to: (selector == 1).then_some(Cow::Borrowed(b"base".as_slice())),
			..Metadata::default()
		})
		.unwrap();
		let mut record = fixture(0, 64);
		record.metadata = metadata;
		let actual = Transport::new(vec![record])
			.and_then(|v| v.encode())
			.map_err(native_error);
		assert_eq!(actual, reference.call(46, &[6, selector]));
	}
}
