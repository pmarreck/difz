use super::*;
use crate::metadata::tests::Reference;
use alloc::{format, vec, vec::Vec};

fn seal(bytes: &mut [u8]) {
	let mut hash = blake3::Hasher::new();
	hash.update(b"DIFZTREE-PATCH\x02");
	hash.update(&bytes[..88]);
	hash.update(&bytes[120..]);
	bytes[88..120].copy_from_slice(hash.finalize().as_bytes());
}
fn compare_error(reference: &mut Reference, bytes: &[u8], expected: Error, limits: EnvelopeLimits) {
	assert_eq!(Header::decode_prefix(bytes, limits), Err(expected));
	let mut request = Vec::new();
	request.extend_from_slice(&limits.max_patch_bytes.to_le_bytes());
	request.extend_from_slice(&u64::from(limits.max_entries).to_le_bytes());
	request.extend_from_slice(&u64::from(limits.max_rules).to_le_bytes());
	request.extend_from_slice(bytes);
	assert_eq!(reference.call(42, &request), Err(format!("{expected:?}")));
}

#[test]
fn native_tree_envelopes_round_trip_with_borrowed_bodies_and_opaque_identities() {
	let mut reference = Reference::start();
	for selector in 0..4 {
		let bytes = reference.call(40, &[selector]).unwrap();
		assert_eq!(reference.call(41, &bytes), Ok(vec![]));
		let (header, body) = Header::decode_prefix(&bytes, EnvelopeLimits::default()).unwrap();
		assert_eq!(header.needed_reader, 2);
		assert_eq!(header.root_metadata, selector == 1);
		assert_eq!(header.omit.bits(), if selector == 0 { 63 } else { 0 });
		assert_eq!(header.rule_count, u32::from(selector == 3));
		assert_eq!(header.entry_count, u32::from(selector == 2));
		assert_eq!(body.as_ptr(), bytes[120..].as_ptr());
		assert_eq!(header.encode(body), bytes[..120]);
		let original_hash = header.source_hash;
		let mut changed = bytes.clone();
		changed[24] ^= 0xff;
		changed[87] ^= 0xff;
		seal(&mut changed);
		assert_eq!(reference.call(41, &changed), Ok(vec![]));
		let (changed_header, _) =
			Header::decode_prefix(&changed, EnvelopeLimits::default()).unwrap();
		assert_ne!(changed_header.source_hash, original_hash);
		assert_ne!(changed_header.target_hash, header.target_hash);
	}
	// Reader requirements 0 and 1 describe this same v2 layout, not v1 support.
	let mut bytes = reference.call(40, &[0]).unwrap();
	for reader in 0..=2u16 {
		bytes[10..12].copy_from_slice(&reader.to_le_bytes());
		for omit in 0..64u32 {
			bytes[12..16].copy_from_slice(&(omit << 1).to_le_bytes());
			seal(&mut bytes);
			assert_eq!(reference.call(41, &bytes), Ok(vec![]));
			let (header, body) = Header::decode_prefix(&bytes, EnvelopeLimits::default()).unwrap();
			assert_eq!(header.needed_reader, reader);
			assert_eq!(header.omit.bits(), omit);
			assert_eq!(header.encode(body), bytes[..120]);
		}
	}
}

#[test]
fn tree_envelope_truncation_corruption_and_error_precedence_match_native() {
	let mut reference = Reference::start();
	let bytes = reference.call(40, &[0]).unwrap();
	let limits = EnvelopeLimits::default();
	for length in 0..120 {
		compare_error(
			&mut reference,
			&bytes[..length],
			Error::UnexpectedEndOfInput,
			limits,
		);
	}
	for position in 0..120 {
		let mut changed = bytes.clone();
		changed[position] ^= 0xff;
		let expected = match position {
			0..8 => Error::InvalidMagic,
			8..10 => Error::UnsupportedVersion,
			_ => Error::PatchHashMismatch,
		};
		compare_error(&mut reference, &changed, expected, limits);
	}
	for version in (0..=255u16).chain([256, 0x102, u16::MAX]) {
		if version == 2 {
			continue;
		}
		let mut changed = bytes.clone();
		changed[8..10].copy_from_slice(&version.to_le_bytes());
		seal(&mut changed);
		compare_error(&mut reference, &changed, Error::UnsupportedVersion, limits);
	}
	for reader in (3..=255u16).chain([256, u16::MAX]) {
		let mut changed = bytes.clone();
		changed[10..12].copy_from_slice(&reader.to_le_bytes());
		seal(&mut changed);
		compare_error(&mut reference, &changed, Error::ReaderTooOld, limits);
	}
	for flags in (128..=255u32)
		.chain((8..32).map(|bit| 1 << bit))
		.chain([u32::MAX])
	{
		let mut changed = bytes.clone();
		changed[12..16].copy_from_slice(&flags.to_le_bytes());
		seal(&mut changed);
		compare_error(&mut reference, &changed, Error::UnsupportedFlags, limits);
	}
	let mut mixed = bytes.clone();
	mixed[10..12].copy_from_slice(&3u16.to_le_bytes());
	mixed[12..16].copy_from_slice(&u32::MAX.to_le_bytes());
	mixed[16..24].fill(0xff);
	seal(&mut mixed);
	compare_error(&mut reference, &mixed, Error::ReaderTooOld, limits);
	mixed[10..12].copy_from_slice(&2u16.to_le_bytes());
	seal(&mut mixed);
	compare_error(&mut reference, &mixed, Error::UnsupportedFlags, limits);
	// A byte ceiling wins even over a short header or malformed magic.
	compare_error(
		&mut reference,
		b"bad",
		Error::LimitExceeded,
		EnvelopeLimits {
			max_patch_bytes: 2,
			..limits
		},
	);
	compare_error(
		&mut reference,
		&bytes,
		Error::LimitExceeded,
		EnvelopeLimits {
			max_patch_bytes: 119,
			..limits
		},
	);
	assert!(
		Header::decode_prefix(
			&bytes,
			EnvelopeLimits {
				max_patch_bytes: 120,
				max_entries: 0,
				max_rules: 0
			}
		)
		.is_ok()
	);
	for selector in [1, 2, 3] {
		let mut changed = reference.call(40, &[selector]).unwrap();
		let last = changed.len() - 1;
		changed[last] ^= 1;
		compare_error(&mut reference, &changed, Error::PatchHashMismatch, limits);
	}
}

#[test]
fn tree_counts_are_checked_before_allocation_using_conservative_body_bounds() {
	let mut reference = Reference::start();
	let bytes = reference.call(40, &[0]).unwrap();
	let limits = EnvelopeLimits::default();
	for (offset, count, expected) in [
		(16, 4096u32, Error::UnexpectedEndOfInput),
		(16, 4097, Error::LimitExceeded),
		(20, 1_000_000, Error::UnexpectedEndOfInput),
		(20, 1_000_001, Error::LimitExceeded),
		(16, u32::MAX, Error::LimitExceeded),
		(20, u32::MAX, Error::LimitExceeded),
	] {
		let mut changed = bytes.clone();
		changed[offset..offset + 4].copy_from_slice(&count.to_le_bytes());
		seal(&mut changed);
		compare_error(&mut reference, &changed, expected, limits);
	}
	for (selector, limits) in [
		(
			2,
			EnvelopeLimits {
				max_entries: 0,
				..limits
			},
		),
		(
			3,
			EnvelopeLimits {
				max_rules: 0,
				..limits
			},
		),
	] {
		let changed = reference.call(40, &[selector]).unwrap();
		compare_error(&mut reference, &changed, Error::LimitExceeded, limits);
	}
	// This is an integrity envelope, not validation of operation/rule bodies.
	// Test the combined lower bound at -1, exact and +1 without allocating
	// untrusted descriptor counts. The complete decoder will validate contents.
	for rules in 0..=4u32 {
		for entries in 0..=4u32 {
			let minimum = rules as usize * 9 + entries as usize * 41;
			for length in minimum.saturating_sub(1)..=minimum + 1 {
				let mut changed = bytes.clone();
				changed[16..20].copy_from_slice(&rules.to_le_bytes());
				changed[20..24].copy_from_slice(&entries.to_le_bytes());
				changed.resize(120 + length, 0);
				seal(&mut changed);
				let parsed = Header::decode_prefix(&changed, limits);
				if length < minimum {
					compare_error(
						&mut reference,
						&changed,
						Error::UnexpectedEndOfInput,
						limits,
					);
				} else {
					let (header, body) = parsed.unwrap();
					assert_eq!(body.len(), length);
					assert_eq!(header.rule_count, rules);
					assert_eq!(header.entry_count, entries);
				}
			}
		}
	}
}
