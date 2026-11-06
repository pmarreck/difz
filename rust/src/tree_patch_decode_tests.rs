use super::*;
use crate::metadata::tests::Reference;
use alloc::{format, string::String, vec, vec::Vec};

fn native_error(error: Error) -> String {
	match error {
		Error::Metadata(error) => format!("{error:?}"),
		Error::Snapshot(error) => format!("{error:?}"),
		Error::Filter(crate::path_filter::Error::Path(error)) => format!("{error:?}"),
		Error::Filter(error) => format!("{error:?}"),
		other => format!("{other:?}"),
	}
}
fn compare(reference: &mut Reference, bytes: &[u8]) {
	let actual = ParsedPatch::decode(bytes, Limits::default())
		.map(|_| vec![])
		.map_err(native_error);
	assert_eq!(actual, reference.call(41, bytes), "patch={bytes:?}");
}
fn checksum(bytes: &mut [u8]) {
	let mut hash = blake3::Hasher::new();
	hash.update(b"DIFZTREE-PATCH\x02");
	hash.update(&bytes[..88]);
	hash.update(&bytes[120..]);
	bytes[88..120].copy_from_slice(hash.finalize().as_bytes());
}
#[test]
fn native_patch_bodies_decode_with_borrowed_fields_and_closed_operations() {
	let mut reference = Reference::start();
	for selector in 0..=4 {
		let bytes = reference.call(40, &[selector]).unwrap();
		compare(&mut reference, &bytes);
		let parsed = ParsedPatch::decode(&bytes, Limits::default()).unwrap();
		assert_eq!(parsed.entries().len(), parsed.header().entry_count as usize);
		assert_eq!(parsed.rules().len(), parsed.header().rule_count as usize);
		for entry in parsed.entries() {
			let begin = bytes.as_ptr() as usize;
			let end = begin + bytes.len();
			for field in [entry.path(), entry.payload()] {
				assert!((begin..=end).contains(&(field.as_ptr() as usize)));
			}
			assert!(crate::directory::Mode::from_bits(entry.mode_bits()).is_ok());
		}
		if selector == 4 {
			assert_eq!(
				parsed
					.entries()
					.iter()
					.map(|e| e.operation() as u8)
					.collect::<Vec<_>>(),
				vec![1, 5, 2, 4, 3, 6]
			);
			assert_eq!(parsed.entries()[1].path(), b"app/base");
			assert_eq!(parsed.entries()[3].payload(), b"\0\xffraw");
			assert_eq!(
				parsed.entries()[5]
					.metadata()
					.metadata()
					.hardlink_to
					.as_deref(),
				Some(b"app/base".as_slice())
			);
		}
	}
	for mask in 0..64 {
		let bytes = reference.call(40, &[4, mask]).unwrap();
		compare(&mut reference, &bytes);
	}
}
#[test]
fn resealed_body_mutations_truncations_and_omitted_metadata_match_native() {
	let mut reference = Reference::start();
	for selector in 0..=4 {
		let bytes = reference.call(40, &[selector]).unwrap();
		for length in 0..bytes.len() {
			let mut cut = bytes[..length].to_vec();
			if cut.len() >= 120 {
				checksum(&mut cut);
			}
			compare(&mut reference, &cut);
		}
		for offset in 120..bytes.len() {
			let mut changed = bytes.clone();
			changed[offset] ^= 0xff;
			checksum(&mut changed);
			compare(&mut reference, &changed);
		}
		let mut extra = bytes.clone();
		extra.push(0);
		checksum(&mut extra);
		compare(&mut reference, &extra);
		for mask in 0..64u32 {
			let mut changed = bytes.clone();
			let flags = u32::from_le_bytes(changed[12..16].try_into().unwrap());
			changed[12..16].copy_from_slice(&((flags & 1) | (mask << 1)).to_le_bytes());
			checksum(&mut changed);
			compare(&mut reference, &changed);
		}
	}
	let bytes = reference.call(40, &[2]).unwrap();
	for value in 0..=255u8 {
		for offset in [120, 121, 122, 123, 124, 128, 136] {
			let mut changed = bytes.clone();
			changed[offset] = value;
			checksum(&mut changed);
			compare(&mut reference, &changed);
		}
	}
}

#[test]
fn body_limits_check_exact_boundaries_and_match_native_error_precedence() {
	let mut reference = Reference::start();
	for selector in 0..=4 {
		let bytes = reference.call(40, &[selector]).unwrap();
		let defaults = Limits::default();
		let mut cases = vec![defaults];
		for length in [0, 119, bytes.len() as u64 - 1, bytes.len() as u64] {
			cases.push(Limits {
				envelope: EnvelopeLimits {
					max_patch_bytes: length,
					..defaults.envelope
				},
				..defaults
			});
		}
		for bound in [0, 1, 2, 6] {
			cases.push(Limits {
				envelope: EnvelopeLimits {
					max_entries: bound,
					..defaults.envelope
				},
				..defaults
			});
			cases.push(Limits {
				envelope: EnvelopeLimits {
					max_rules: bound,
					..defaults.envelope
				},
				..defaults
			});
		}
		for bound in [0, 1, 2, 3, 4, 5, 7, 8, 19, 20, 21, 1024] {
			cases.push(Limits {
				max_path_bytes: bound,
				..defaults
			});
			cases.push(Limits {
				max_pattern_bytes: bound,
				..defaults
			});
			cases.push(Limits {
				max_symlink_bytes: u64::from(bound),
				..defaults
			});
			cases.push(Limits {
				max_payload_bytes: u64::from(bound),
				..defaults
			});
		}
		for limits in cases {
			let mut request = Vec::new();
			for value in [
				limits.envelope.max_patch_bytes,
				u64::from(limits.envelope.max_entries),
				u64::from(limits.envelope.max_rules),
				u64::from(limits.max_path_bytes),
				u64::from(limits.max_pattern_bytes),
				limits.max_symlink_bytes,
				limits.max_payload_bytes,
			] {
				request.extend_from_slice(&value.to_le_bytes());
			}
			request.extend_from_slice(&bytes);
			let actual = ParsedPatch::decode(&bytes, limits)
				.map(|_| vec![])
				.map_err(native_error);
			assert_eq!(
				actual,
				reference.call(44, &request),
				"fixture={selector} limits={limits:?}"
			);
		}
	}
}
