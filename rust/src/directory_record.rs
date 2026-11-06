use super::Error;
use crate::metadata::CanonicalMetadata;
use alloc::{borrow::Cow, vec::Vec};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Mode(u16);
impl Mode {
	pub fn from_bits(bits: u16) -> Result<Self, Error> {
		if bits & !0o777 != 0 {
			return Err(Error::InvalidMode);
		}
		Ok(Self(bits))
	}
	pub const fn bits(self) -> u16 {
		self.0
	}
}

/// Expanded snapshot content. Directories have no data and symlinks always
/// expose mode 0777; file and directory modes carry only portable bits.
#[derive(Debug, Eq, PartialEq)]
pub enum Content<'a> {
	Directory { mode: Mode },
	File { mode: Mode, bytes: Cow<'a, [u8]> },
	Symlink { target: Cow<'a, [u8]> },
}
impl Content<'_> {
	pub const fn kind_tag(&self) -> u8 {
		match self {
			Self::Directory { mode: _ } => 1,
			Self::File { mode: _, bytes: _ } => 2,
			Self::Symlink { target: _ } => 3,
		}
	}
	pub const fn mode(&self) -> Mode {
		match self {
			Self::Directory { mode } | Self::File { mode, bytes: _ } => *mode,
			Self::Symlink { target: _ } => Mode(0o777),
		}
	}
	pub fn bytes(&self) -> &[u8] {
		match self {
			Self::Directory { mode: _ } => &[],
			Self::File { mode: _, bytes } => bytes,
			Self::Symlink { target } => target,
		}
	}
}

/// Raw records own descriptors and may borrow or own bytes. Paths, hierarchy,
/// symlink containment and physical metadata relations still need validation.
#[derive(Debug, Eq, PartialEq)]
pub struct Entry<'a> {
	pub path: Cow<'a, [u8]>,
	pub content: Content<'a>,
	pub metadata: CanonicalMetadata<'a>,
}
#[derive(Debug, Default, Eq, PartialEq)]
pub struct Snapshot<'a> {
	pub entries: Vec<Entry<'a>>,
	pub root: CanonicalMetadata<'a>,
}
