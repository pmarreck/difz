use super::*;
use crate::metadata::{Ace, AceTag, Permissions};
use crate::metadata::{CanonicalMetadata, Metadata, Omit, tests::Reference};
use alloc::{borrow::Cow, vec};
use alloc::{format, vec::Vec};

fn raw(entries: &[(u16, u16, u32)]) -> Vec<u8> {
	let mut bytes = 2u32.to_le_bytes().to_vec();
	for (tag, perm, id) in entries {
		bytes.extend_from_slice(&tag.to_le_bytes());
		bytes.extend_from_slice(&perm.to_le_bytes());
		bytes.extend_from_slice(&id.to_le_bytes());
	}
	bytes
}
fn fixture() -> Vec<u8> {
	raw(&[
		(1, 7, u32::MAX),
		(2, 4, 123),
		(4, 5, u32::MAX),
		(16, 5, u32::MAX),
		(32, 0, u32::MAX),
	])
}
fn compare(reference: &mut Reference, bytes: &[u8]) {
	let result = PosixAcl::new(bytes)
		.and_then(|acl| acl.portable())
		.map_err(|e| format!("{e:?}"))
		.map(|aces| {
			CanonicalMetadata::normalize(
				Metadata {
					aces,
					..Metadata::default()
				},
				Omit::default(),
			)
			.unwrap()
			.encode()
			.unwrap()
		});
	assert_eq!(result, reference.call(48, bytes), "raw ACL={bytes:?}");
}
#[test]
fn linux_permissions_tags_ids_and_portable_names_match_native() {
	let mut reference = Reference::start();
	compare(&mut reference, &[]);
	for owner in 0..8 {
		for group in 0..8 {
			for other in 0..8 {
				compare(
					&mut reference,
					&raw(&[
						(1, owner, u32::MAX),
						(4, group, u32::MAX),
						(32, other, u32::MAX),
					]),
				);
			}
		}
	}
	for tag in [0, 1, 2, 3, 4, 8, 16, 32, 64, u16::MAX] {
		for id in [0, 1, 123, u32::MAX - 1, u32::MAX] {
			compare(
				&mut reference,
				&raw(&[
					(1, 7, u32::MAX),
					(tag, 4, id),
					(4, 5, u32::MAX),
					(16, 5, u32::MAX),
					(32, 0, u32::MAX),
				]),
			);
		}
	}
	for perm in 0..=256 {
		compare(
			&mut reference,
			&raw(&[
				(1, perm, u32::MAX),
				(2, 7, 0),
				(2, 1, u32::MAX - 1),
				(4, 5, u32::MAX),
				(8, 3, 123),
				(16, 5, u32::MAX),
				(32, 0, u32::MAX),
			]),
		);
	}
	let bytes = fixture();
	for length in 0..bytes.len() {
		compare(&mut reference, &bytes[..length]);
	}
	for offset in 0..bytes.len() {
		let mut changed = bytes.clone();
		changed[offset] ^= 0xff;
		compare(&mut reference, &changed);
	}
}
#[test]
fn linux_acl_container_encoding_and_borrowed_decoding_match_native() {
	let mut reference = Reference::start();
	let rich = fixture();
	for access in [b"".as_slice(), rich.as_slice()] {
		for default in [b"".as_slice(), rich.as_slice()] {
			let acl = LinuxAcl {
				access: PosixAcl::new(access).unwrap(),
				default: PosixAcl::new(default).unwrap(),
			};
			let bytes = acl.encode().unwrap();
			let mut request = (access.len() as u32).to_le_bytes().to_vec();
			request.extend_from_slice(access);
			request.extend_from_slice(default);
			assert_eq!(bytes, reference.call(52, &request).unwrap());
			let parsed = LinuxAcl::decode(&bytes).unwrap();
			assert_eq!(parsed.access.bytes(), access);
			assert_eq!(parsed.default.bytes(), default);
			assert_eq!(parsed.access.bytes().as_ptr(), bytes[16..].as_ptr());
			let mut cases: Vec<Vec<u8>> = (0..bytes.len()).map(|n| bytes[..n].to_vec()).collect();
			for offset in 0..bytes.len() {
				let mut changed = bytes.clone();
				changed[offset] ^= 0xff;
				cases.push(changed);
			}
			let mut trailing = bytes.clone();
			trailing.push(0);
			cases.push(trailing);
			for changed in cases {
				let actual = LinuxAcl::decode(&changed)
					.and_then(|acl| acl.encode())
					.map_err(|e| format!("{e:?}"));
				assert_eq!(
					actual,
					reference.call(49, &changed),
					"container={changed:?}"
				);
			}
		}
	}
}

#[test]
fn portable_to_kernel_acl_matches_native_numeric_grammar_and_ordering() {
	let mut reference = Reference::start();
	let samples: [&[u8]; 24] = [
		b"0",
		b"1",
		b"123",
		b"4294967294",
		b"4294967295",
		b"4294967296",
		b"+0",
		b"-0",
		b"-1",
		b"+12",
		b"1_2",
		b"1__2",
		b"_12",
		b"12_",
		b"+",
		b"-",
		b"00",
		b"-0_0",
		b" 1",
		b"1 ",
		b"0x1",
		b"user",
		"１２".as_bytes(),
		b"999999999999999999999999",
	];
	for name in samples {
		let base = fixture();
		let mut aces = PosixAcl::new(&base).unwrap().portable().unwrap();
		aces.iter_mut()
			.find(|ace| ace.tag == AceTag::NamedUser)
			.unwrap()
			.name = Cow::Owned(name.to_vec());
		let metadata = CanonicalMetadata::normalize(
			Metadata {
				aces,
				..Metadata::default()
			},
			Omit::default(),
		)
		.unwrap();
		let actual = encode_portable(&metadata).map_err(|e| format!("{e:?}"));
		assert_eq!(
			actual,
			reference.call(53, &metadata.encode().unwrap()),
			"name={name:?}"
		);
	}
	for names in [["10", "2"], ["1", "+1"], ["0", "-0"], ["123", "4294967294"]] {
		let base = fixture();
		let mut aces = PosixAcl::new(&base).unwrap().portable().unwrap();
		aces.iter_mut()
			.find(|ace| ace.tag == AceTag::NamedUser)
			.unwrap()
			.name = Cow::Owned(names[0].as_bytes().to_vec());
		aces.push(Ace {
			tag: AceTag::NamedUser,
			permissions: Permissions::READ,
			name: Cow::Owned(names[1].as_bytes().to_vec()),
		});
		let metadata = CanonicalMetadata::normalize(
			Metadata {
				aces,
				..Metadata::default()
			},
			Omit::default(),
		)
		.unwrap();
		assert_eq!(
			encode_portable(&metadata).map_err(|e| format!("{e:?}")),
			reference.call(53, &metadata.encode().unwrap())
		);
	}
	let empty = CanonicalMetadata::default();
	assert_eq!(
		encode_portable(&empty).unwrap(),
		reference.call(53, &empty.encode().unwrap()).unwrap()
	);
	let missing = CanonicalMetadata::new(Metadata {
		aces: vec![Ace {
			tag: AceTag::Owner,
			permissions: Permissions::READ,
			name: Cow::Borrowed(b""),
		}],
		..Metadata::default()
	})
	.unwrap();
	assert_eq!(
		encode_portable(&missing).map_err(|e| format!("{e:?}")),
		reference.call(53, &missing.encode().unwrap())
	);
}
