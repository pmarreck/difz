//! Bounded capture of canonical records preserved in Linux transport attributes.
use crate::{Error, linux_metadata, xattr};
use difz_core::metadata::{CanonicalMetadata, Xattr, XattrClass};
use std::{borrow::Cow, fs::File};

/// Native values take precedence over duplicate raw records in transport.
/// Native list bytes, transport bytes and retained name/value bytes each have
/// the same ceiling. Descriptor count includes every retained attribute.
/// Work is O(n log n) name comparisons plus linear retained byte copying.
pub fn capture_xattrs(
	file: &File,
	maximum_names: usize,
	maximum_bytes: usize,
) -> Result<Vec<Xattr<'static>>, Error> {
	let mut native = linux_metadata::capture_native_xattrs(file, maximum_names, maximum_bytes)?;
	let sidecar = optional(file, b"user.difz.raw-xattrs", maximum_bytes)?;
	if let Some(bytes) = sidecar {
		merge_raw(&mut native, &bytes, maximum_names, maximum_bytes)?;
	}
	Ok(native)
}

pub(crate) fn optional(file: &File, name: &[u8], maximum: usize) -> Result<Option<Vec<u8>>, Error> {
	match xattr::get(file, name, maximum) {
		Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENOTSUP) => Ok(None),
		other => other,
	}
}

fn merge_raw(
	native: &mut Vec<Xattr<'static>>,
	bytes: &[u8],
	maximum_names: usize,
	maximum_bytes: usize,
) -> Result<(), Error> {
	let decoded = CanonicalMetadata::decode(bytes).map_err(Error::Metadata)?;
	native.sort_unstable_by(|a, b| (a.class, a.name.as_ref()).cmp(&(b.class, b.name.as_ref())));
	let native_count = native.len();
	let mut remaining = maximum_bytes;
	for value in native.iter() {
		account(&mut remaining, value.name.len(), value.value.len())?;
	}
	// The decoded sidecar is canonical, so its raw records are unique. Search
	// only the original sorted native prefix while appending owned sidecar data.
	for value in &decoded.metadata().xattrs {
		if value.class != XattrClass::Raw
			|| native[..native_count]
				.binary_search_by(|other| {
					(other.class, other.name.as_ref()).cmp(&(value.class, value.name.as_ref()))
				})
				.is_ok()
		{
			continue;
		}
		if native.len() >= maximum_names {
			return Err(Error::LimitExceeded);
		}
		account(&mut remaining, value.name.len(), value.value.len())?;
		let name = owned(&value.name)?;
		let bytes = owned(&value.value)?;
		native.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
		native.push(Xattr {
			class: XattrClass::Raw,
			name: Cow::Owned(name),
			value: Cow::Owned(bytes),
		});
	}
	Ok(())
}

fn account(remaining: &mut usize, name: usize, value: usize) -> Result<(), Error> {
	*remaining = remaining
		.checked_sub(name)
		.and_then(|n| n.checked_sub(value))
		.ok_or(Error::LimitExceeded)?;
	Ok(())
}

pub(crate) fn owned(bytes: &[u8]) -> Result<Vec<u8>, Error> {
	let mut result = Vec::new();
	result
		.try_reserve_exact(bytes.len())
		.map_err(|_| Error::OutOfMemory)?;
	result.extend_from_slice(bytes);
	Ok(result)
}

#[cfg(test)]
mod tests {
	use super::*;
	use difz_core::metadata::{Metadata, Omit};
	fn attr(class: XattrClass, name: &[u8], value: &[u8]) -> Xattr<'static> {
		Xattr {
			class,
			name: Cow::Owned(name.to_vec()),
			value: Cow::Owned(value.to_vec()),
		}
	}
	fn encode(xattrs: Vec<Xattr<'static>>) -> Vec<u8> {
		CanonicalMetadata::normalize(
			Metadata {
				xattrs,
				..Metadata::default()
			},
			Omit::default(),
		)
		.unwrap()
		.encode()
		.unwrap()
	}
	#[test]
	fn raw_transport_merging_retains_native_precedence_and_only_raw_records() {
		let bytes = encode(vec![
			attr(XattrClass::Raw, b"user.raw\xff", b"stale"),
			attr(XattrClass::Raw, b"foreign\xff", b"\0\xffsidecar"),
			attr(XattrClass::Logical, b"ignored", b"not captured"),
		]);
		let mut native = vec![
			attr(XattrClass::Raw, b"user.raw\xff", b"kernel"),
			attr(XattrClass::Logical, b"name", b""),
		];
		merge_raw(&mut native, &bytes, 3, 100).unwrap();
		assert_eq!(native.len(), 3);
		assert!(
			native
				.iter()
				.any(|a| a.name.as_ref() == b"user.raw\xff" && a.value.as_ref() == b"kernel")
		);
		assert!(
			native
				.iter()
				.any(|a| a.name.as_ref() == b"foreign\xff" && a.value.as_ref() == b"\0\xffsidecar")
		);
		assert!(native.iter().all(|a| a.name.as_ref() != b"ignored"));
		// Returned bytes outlive the decoded transport buffer.
		drop(bytes);
		assert!(
			native
				.iter()
				.all(|a| matches!(a.name, Cow::Owned(_)) && matches!(a.value, Cow::Owned(_)))
		);
	}
	#[test]
	fn raw_transport_enforces_combined_counts_bytes_and_canonical_grammar() {
		let bytes = encode(vec![attr(XattrClass::Raw, b"raw", b"\0\xff")]);
		for maximum in 0..5 {
			assert!(matches!(
				merge_raw(&mut vec![], &bytes, 1, maximum),
				Err(Error::LimitExceeded)
			));
		}
		assert!(merge_raw(&mut vec![], &bytes, 1, 5).is_ok());
		assert!(matches!(
			merge_raw(&mut vec![], &bytes, 0, 5),
			Err(Error::LimitExceeded)
		));
		let mut native = vec![attr(XattrClass::Logical, b"x", b"y")];
		assert!(matches!(
			merge_raw(&mut native, &bytes, 2, 6),
			Err(Error::LimitExceeded)
		));
		for length in 0..bytes.len() {
			assert!(matches!(
				merge_raw(&mut vec![], &bytes[..length], 8, 100),
				Err(Error::Metadata(_))
			));
		}
		let mut trailing = bytes;
		trailing.push(0);
		assert!(matches!(
			merge_raw(&mut vec![], &trailing, 8, 100),
			Err(Error::Metadata(_))
		));
	}
}
