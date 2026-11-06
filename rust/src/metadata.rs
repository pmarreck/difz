//! Portable metadata primitives. Variable-size canonical records follow separately.

macro_rules! families {
    ($( $variant:ident = $tag:literal => $name:literal ),+ $(,)?) => {
        #[repr(u8)]
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub enum Family { $( $variant = $tag ),+ }
        impl Family {
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];
            const MASK: u32 = 0 $( | Self::$variant.bit() )+;
            pub const fn name(self) -> &'static str { match self { $(Self::$variant => $name),+ } }
            pub const fn bit(self) -> u32 { 1 << (self as u8 - 1) }
        }
    };
}
families! { Xattr = 1 => "xattr", Acl = 2 => "acl", Timestamps = 3 => "timestamps", Finder = 4 => "finder", Sparse = 5 => "sparse", Hardlink = 6 => "hardlink" }

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	InvalidOmitMask,
	EmptyFamily,
	UnknownFamily,
	DuplicateFamily,
	InvalidNsec,
	BadMetadata,
	EmptyName,
	InvalidLogicalName,
	ReservedTransportName,
	InvalidRawName,
	InvalidHardlink,
	InvalidAceName,
	OutOfMemory,
	DuplicateXattr,
	DuplicateAce,
	EmptyNativeAcl,
	ZeroLengthHole,
	HoleOverflow,
	TruncatedMetadata,
	TrailingMetadata,
}

macro_rules! wire_enum {
	($name:ident { $( $variant:ident = $tag:literal ),+ $(,)? }) => {
		#[repr(u8)]
		#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
		pub enum $name { $( $variant = $tag ),+ }
		impl $name { pub const ALL: &'static [Self] = &[$(Self::$variant),+]; }
		impl TryFrom<u8> for $name {
			type Error = Error;
			fn try_from(tag: u8) -> Result<Self, Error> {
				match tag { $( $tag => Ok(Self::$variant), )+ _ => Err(Error::BadMetadata) }
			}
		}
	};
}
wire_enum! { Os { Linux = 1, Macos = 2, Mswin = 3 } }
pub type AclOrigin = Os;
wire_enum! { XattrClass { Logical = 1, Raw = 2 } }
wire_enum! { AceTag { Owner = 1, Group = 2, Everyone = 3, NamedUser = 4, NamedGroup = 5, Mask = 6 } }

pub const TRANSPORT_NAMES: &[&[u8]] = &[
	b"difz.btime",
	b"difz.mtime",
	b"difz.finder-info",
	b"difz.bsd-flags",
	b"difz.native-acl",
	b"difz.portable-acl",
	b"difz.sparse-holes",
	b"difz.hardlink-to",
	b"difz.raw-xattrs",
	b"difz.symlinks",
];

pub fn is_transport_name(name: &[u8]) -> bool {
	let bare = name.strip_prefix(b"user.").unwrap_or(name);
	TRANSPORT_NAMES.contains(&bare)
}
const FORBIDDEN: &[u8] = b"/\\:*?\"<>|";
pub fn validate_xattr_name(class: XattrClass, name: &[u8]) -> Result<(), Error> {
	if is_transport_name(name) {
		return Err(Error::ReservedTransportName);
	}
	if name.is_empty() {
		return Err(Error::EmptyName);
	}
	match class {
		XattrClass::Logical => {
			if name.len() > 127
				|| name
					.iter()
					.any(|byte| *byte < 0x20 || *byte == 0x7f || FORBIDDEN.contains(byte))
				|| core::str::from_utf8(name).is_err()
				|| name[0] == b' '
				|| name.ends_with(b" ")
				|| name.ends_with(b".")
				|| [b"user.".as_slice(), b"com.apple.", b"$"]
					.iter()
					.any(|prefix| {
						name.get(..prefix.len())
							.is_some_and(|head| head.eq_ignore_ascii_case(prefix))
					}) || name.eq_ignore_ascii_case(b"zone.identifier")
			{
				return Err(Error::InvalidLogicalName);
			}
		}
		XattrClass::Raw => {
			if name.len() > 255 || name.iter().any(|byte| matches!(byte, 0 | b'/' | b'\\')) {
				return Err(Error::InvalidRawName);
			}
		}
	}
	Ok(())
}
pub fn validate_hardlink(path: &[u8]) -> Result<(), Error> {
	if path.is_empty()
		|| path.len() > 4096
		|| core::str::from_utf8(path).is_err()
		|| path.starts_with(b"/")
		|| path.contains(&b'\\')
		|| path.contains(&0)
		|| (path.len() >= 2 && path[0].is_ascii_alphabetic() && path[1] == b':')
		|| path
			.split(|byte| *byte == b'/')
			.any(|part| part.is_empty() || part == b"." || part == b"..")
	{
		return Err(Error::InvalidHardlink);
	}
	Ok(())
}
pub fn validate_ace_name(tag: AceTag, name: &[u8]) -> Result<(), Error> {
	let valid = match tag {
		AceTag::NamedUser | AceTag::NamedGroup => {
			!name.is_empty()
				&& core::str::from_utf8(name).is_ok()
				&& !name.contains(&b'/')
				&& !name.contains(&0)
		}
		AceTag::Owner | AceTag::Group | AceTag::Everyone | AceTag::Mask => name.is_empty(),
	};
	if !valid {
		return Err(Error::InvalidAceName);
	}
	Ok(())
}
/// Platform eligibility only. Callers must first validate the raw xattr name.
pub fn raw_accepted(os: Os, name: &[u8]) -> bool {
	match os {
		Os::Linux => [b"user.".as_slice(), b"system.", b"security.", b"trusted."]
			.iter()
			.any(|prefix| name.starts_with(prefix) && name.len() > prefix.len()),
		Os::Macos => !name.is_empty() && name.len() <= 127 && !name.contains(&b'/'),
		Os::Mswin => {
			!name.is_empty()
				&& name.len() <= 255
				&& !name.iter().any(|byte| FORBIDDEN.contains(byte))
		}
	}
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Omit(u32);
impl Omit {
	pub fn from_bits(bits: u32) -> Result<Self, Error> {
		if bits & !Family::MASK != 0 {
			return Err(Error::InvalidOmitMask);
		}
		Ok(Self(bits))
	}
	pub const fn bits(self) -> u32 {
		self.0
	}
	pub const fn contains(self, family: Family) -> bool {
		self.0 & family.bit() != 0
	}
	pub fn parse(text: &[u8]) -> Result<Self, Error> {
		let mut omit = Self::default();
		if text.is_empty() {
			return Ok(omit);
		}
		for mut name in text.split(|byte| *byte == b',') {
			// Only ASCII space is padding in the existing omission grammar.
			while let Some(tail) = name.strip_prefix(b" ") {
				name = tail;
			}
			while let Some(head) = name.strip_suffix(b" ") {
				name = head;
			}
			if name.is_empty() {
				return Err(Error::EmptyFamily);
			}
			let family = Family::ALL
				.iter()
				.copied()
				.find(|family| family.name().as_bytes() == name)
				.ok_or(Error::UnknownFamily)?;
			if omit.contains(family) {
				return Err(Error::DuplicateFamily);
			}
			omit.0 |= family.bit();
		}
		Ok(omit)
	}
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Time {
	pub sec: i64,
	pub nsec: u32,
}
impl Time {
	fn encode(self) -> Result<[u8; 12], Error> {
		let Self { sec, nsec } = self;
		if nsec >= 1_000_000_000 {
			return Err(Error::InvalidNsec);
		}
		let mut bytes = [0; 12];
		bytes[..8].copy_from_slice(&sec.to_le_bytes());
		bytes[8..].copy_from_slice(&nsec.to_le_bytes());
		Ok(bytes)
	}
	fn decode(bytes: &[u8]) -> Result<Self, Error> {
		if bytes.len() != 12 {
			return Err(Error::BadMetadata);
		}
		let sec = i64::from_le_bytes(bytes[..8].try_into().map_err(|_| Error::BadMetadata)?);
		let nsec = u32::from_le_bytes(bytes[8..].try_into().map_err(|_| Error::BadMetadata)?);
		if nsec >= 1_000_000_000 {
			return Err(Error::InvalidNsec);
		}
		Ok(Self { sec, nsec })
	}
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ModificationOverride {
	pub original: Option<Time>,
	pub observed: Time,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InlineBytes<const N: usize> {
	bytes: [u8; N],
	length: usize,
}
impl<const N: usize> InlineBytes<N> {
	pub fn as_bytes(&self) -> &[u8] {
		&self.bytes[..self.length]
	}
}

pub fn encode_time_override(value: Option<Time>) -> Result<InlineBytes<13>, Error> {
	let mut output = InlineBytes {
		bytes: [0; 13],
		length: 1,
	};
	if let Some(time) = value {
		output.bytes[0] = 1;
		output.bytes[1..].copy_from_slice(&time.encode()?);
		output.length = 13;
	}
	Ok(output)
}
pub fn decode_time_override(bytes: &[u8]) -> Result<Option<Time>, Error> {
	if bytes == [0] {
		return Ok(None);
	}
	if bytes.len() != 13 || bytes[0] != 1 {
		return Err(Error::BadMetadata);
	}
	Time::decode(&bytes[1..]).map(Some)
}
pub fn encode_modification_override(value: ModificationOverride) -> Result<InlineBytes<25>, Error> {
	let ModificationOverride { original, observed } = value;
	let original = encode_time_override(original)?;
	let observed = observed.encode()?;
	let prefix = original.as_bytes().len();
	let mut output = InlineBytes {
		bytes: [0; 25],
		length: prefix + observed.len(),
	};
	output.bytes[..prefix].copy_from_slice(original.as_bytes());
	output.bytes[prefix..output.length].copy_from_slice(&observed);
	Ok(output)
}
pub fn decode_modification_override(bytes: &[u8]) -> Result<ModificationOverride, Error> {
	if bytes.len() != 13 && bytes.len() != 25 {
		return Err(Error::BadMetadata);
	}
	let prefix = bytes.len() - 12;
	let original = decode_time_override(&bytes[..prefix])?;
	let observed = Time::decode(&bytes[prefix..])?;
	Ok(ModificationOverride { original, observed })
}

#[path = "metadata_record.rs"]
mod record;
pub use record::{Ace, Hole, Metadata, NativeAcl, Permissions, Times, Xattr};

#[path = "metadata_canonical.rs"]
mod canonical;
pub use canonical::CanonicalMetadata;

#[path = "metadata_decode.rs"]
mod decode;

#[path = "metadata_restore.rs"]
mod restore;
pub use restore::{
	Capabilities, Compromise, CompromiseCode, RestoreActions, RestoreError, RestorePlan,
	RestoreReport,
};

#[cfg(test)]
#[path = "metadata_tests.rs"]
mod tests;
