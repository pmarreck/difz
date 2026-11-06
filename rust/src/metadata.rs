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

#[cfg(test)]
#[path = "metadata_tests.rs"]
mod tests;
