use super::Reference;
use crate::metadata::*;
use alloc::{borrow::Cow, vec::Vec};

fn caps(os: Os, bits: u8) -> Capabilities {
	Capabilities {
		os,
		set_btime: bits & 1 != 0,
		punch_holes: bits & 2 != 0,
		hardlink: bits & 4 != 0,
		portable_acl: bits & 8 != 0,
		native_acl: bits & 16 != 0,
		bsd_flags: bits & 32 != 0,
		finder_info: bits & 64 != 0,
		logical_xattr: bits & 128 != 0,
	}
}
fn cap_bits(caps: Capabilities) -> u8 {
	let Capabilities {
		os: _,
		set_btime,
		punch_holes,
		hardlink,
		portable_acl,
		native_acl,
		bsd_flags,
		finder_info,
		logical_xattr,
	} = caps;
	[
		set_btime,
		punch_holes,
		hardlink,
		portable_acl,
		native_acl,
		bsd_flags,
		finder_info,
		logical_xattr,
	]
	.into_iter()
	.enumerate()
	.fold(0, |bits, (index, flag)| bits | (u8::from(flag) << index))
}
fn encode_plan(plan: RestorePlan) -> Vec<u8> {
	let RestoreActions {
		logical_xattr,
		raw_xattr,
		raw_xattr_sidecar,
		portable_acl,
		portable_acl_sidecar,
		native_acl,
		native_acl_sidecar,
		mtime_atime,
		btime,
		btime_sidecar,
		bsd_flags,
		bsd_flags_sidecar,
		finder_info,
		finder_info_sidecar,
		punch_holes,
		sparse_sidecar,
		hardlink,
		hardlink_copy,
	} = *plan.actions();
	let flags = [
		logical_xattr,
		raw_xattr,
		raw_xattr_sidecar,
		portable_acl,
		portable_acl_sidecar,
		native_acl,
		native_acl_sidecar,
		mtime_atime,
		btime,
		btime_sidecar,
		bsd_flags,
		bsd_flags_sidecar,
		finder_info,
		finder_info_sidecar,
		punch_holes,
		sparse_sidecar,
		hardlink,
		hardlink_copy,
	]
	.into_iter()
	.enumerate()
	.fold(0u32, |bits, (index, flag)| {
		bits | (u32::from(flag) << index)
	});
	let mut wire = flags.to_le_bytes().to_vec();
	wire.push(plan.compromises().len() as u8);
	for &compromise in plan.compromises() {
		let (applied, origin) = match compromise {
			Compromise::NativeAclPreserved {
				origin,
				portable_acl_applied,
			} => (u8::from(portable_acl_applied), origin as u8),
			Compromise::PortableAclPreserved
			| Compromise::FinderFlagsPreserved
			| Compromise::FinderInfoPreserved
			| Compromise::BirthTimePreserved
			| Compromise::SparsePreserved
			| Compromise::HardlinkCopied
			| Compromise::RawXattrPreserved => (0, 0),
		};
		wire.extend([
			compromise.code() as u8,
			compromise.family() as u8,
			applied,
			origin,
		]);
	}
	wire
}
fn compare_plans(reference: &mut Reference, metadata: &CanonicalMetadata<'_>, wire: &[u8]) {
	for &os in Os::ALL {
		for bits in 0..=255u8 {
			let actual = RestorePlan::new(metadata, caps(os, bits))
				.map(encode_plan)
				.map_err(|e| format!("{e:?}"));
			let mut input = vec![os as u8, bits];
			input.extend(wire);
			assert_eq!(actual, reference.call(20, &input), "os={os:?} bits={bits}");
		}
	}
}

#[test]
fn restore_plans_match_native_actions_and_ordered_warnings_for_all_capabilities() {
	let mut reference = Reference::start();
	for selector in [0, 1, 2, 3, 8, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31] {
		let wire = reference.call(12, &[selector]).unwrap();
		let metadata = CanonicalMetadata::decode(&wire).unwrap();
		compare_plans(&mut reference, &metadata, &wire);
	}
	let long = vec![b'x'; 128];
	for name in [
		b"user.accepted".as_slice(),
		b"colon:name",
		b"binary\xff",
		long.as_slice(),
	] {
		let raw = Metadata {
			xattrs: vec![Xattr {
				class: XattrClass::Raw,
				name: Cow::Borrowed(name),
				value: Cow::Borrowed(b"\0\xff"),
			}],
			..Metadata::default()
		};
		let metadata = CanonicalMetadata::new(raw).unwrap();
		compare_plans(&mut reference, &metadata, &metadata.encode().unwrap());
	}
	// Isolated zero-valued presence distinguishes each timestamp and FinderInfo
	// from absence, and prevents another present field from masking an omission.
	for raw in [
		Metadata {
			times: Times {
				mtime: Some(Time { sec: 0, nsec: 0 }),
				..Times::default()
			},
			..Metadata::default()
		},
		Metadata {
			times: Times {
				atime: Some(Time { sec: 0, nsec: 0 }),
				..Times::default()
			},
			..Metadata::default()
		},
		Metadata {
			times: Times {
				btime: Some(Time { sec: 0, nsec: 0 }),
				..Times::default()
			},
			..Metadata::default()
		},
		Metadata {
			finder_info: Some([0; 32]),
			..Metadata::default()
		},
		Metadata {
			finder_flags: 1,
			..Metadata::default()
		},
	] {
		let metadata = CanonicalMetadata::new(raw).unwrap();
		compare_plans(&mut reference, &metadata, &metadata.encode().unwrap());
	}
}

#[test]
fn default_capabilities_and_all_report_combinations_match_native() {
	let mut reference = Reference::start();
	for &os in Os::ALL {
		assert_eq!(
			vec![cap_bits(Capabilities::for_os(os))],
			reference.call(21, &[os as u8]).unwrap()
		);
	}
	for mask in 0..(1u32 << CompromiseCode::ALL.len()) {
		let mut report = RestoreReport::default();
		let mut codes = Vec::new();
		for &code in CompromiseCode::ALL {
			if mask & (1 << (code as u8 - 1)) != 0 {
				// Repeated restoration effects accumulate idempotently.
				for _ in 0..2 {
					report.add(code);
					codes.push(code as u8);
				}
			}
		}
		assert_eq!(report.bits(), mask);
		assert_eq!(
			report.bits().to_le_bytes().to_vec(),
			reference.call(22, &codes).unwrap()
		);
	}
}
