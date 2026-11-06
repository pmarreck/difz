//! Native name mapping, separate from canonical metadata reservations.
use super::{Os, XattrClass};
use core::ffi::CStr;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	InvalidName,
}
/// Write a terminated native name into caller storage without allocation.
/// Errors leave output untouched. Known difz transport names are addressable;
/// canonical user metadata applies its separate reservation rule.
pub fn to_native<'out>(
	os: Os,
	class: XattrClass,
	name: &[u8],
	output: &'out mut [u8],
) -> Result<&'out CStr, Error> {
	match class {
		XattrClass::Logical => {
			super::validate_logical_name(name).map_err(|_| Error::InvalidName)?
		}
		XattrClass::Raw => {
			let maximum = match os {
				Os::Linux | Os::Mswin => 255,
				Os::Macos => 127,
			};
			if name.is_empty()
				|| name.len() > maximum
				|| name.contains(&0)
				|| (os == Os::Mswin
					&& (name.iter().any(|byte| b":\\/".contains(byte))
						|| core::str::from_utf8(name).is_err()))
			{
				return Err(Error::InvalidName);
			}
		}
	}
	let prefix: &[u8] = if os == Os::Linux && class == XattrClass::Logical {
		b"user."
	} else {
		b""
	};
	let length = prefix.len() + name.len();
	if output.len() <= length {
		return Err(Error::InvalidName);
	}
	output[..prefix.len()].copy_from_slice(prefix);
	output[prefix.len()..length].copy_from_slice(name);
	output[length] = 0;
	CStr::from_bytes_with_nul(&output[..length + 1]).map_err(|_| Error::InvalidName)
}
/// Logical mode returns only names reachable through the portable grammar.
/// Raw mode borrows the input unchanged, matching the native listing API;
/// it is not a validation operation.
pub fn from_native(os: Os, class: XattrClass, native: &[u8]) -> Option<&[u8]> {
	match class {
		XattrClass::Raw => Some(native),
		XattrClass::Logical => {
			let logical = match os {
				Os::Linux => native.strip_prefix(b"user.")?,
				Os::Macos | Os::Mswin => native,
			};
			super::validate_logical_name(logical)
				.is_ok()
				.then_some(logical)
		}
	}
}
#[cfg(test)]
#[path = "attribute_name_tests.rs"]
mod tests;
