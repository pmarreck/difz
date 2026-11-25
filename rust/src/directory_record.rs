use super::Error;
use crate::metadata::CanonicalMetadata;
use alloc::{borrow::Cow, vec::Vec};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Mode(u16);
impl Mode {
	pub const fn from_bits(bits: u16) -> Result<Self, Error> {
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
	Directory {
		mode: Mode,
	},
	File {
		mode: Mode,
		bytes: Cow<'a, [u8]>,
	},
	/// An earlier canonical file owns the bytes. Indices survive entry-vector
	/// growth without self-references or another allocation per hardlink.
	FileAlias {
		mode: Mode,
		target: usize,
	},
	Symlink {
		target: Cow<'a, [u8]>,
	},
}
impl Content<'_> {
	pub const fn kind_tag(&self) -> u8 {
		match self {
			Self::Directory { mode: _ } => 1,
			Self::File { mode: _, bytes: _ } => 2,
			Self::FileAlias { mode: _, target: _ } => 2,
			Self::Symlink { target: _ } => 3,
		}
	}
	pub const fn mode(&self) -> Mode {
		match self {
			Self::Directory { mode }
			| Self::File { mode, bytes: _ }
			| Self::FileAlias { mode, target: _ } => *mode,
			Self::Symlink { target: _ } => Mode(0o777),
		}
	}
	/// Direct bytes, or None when an alias requires the containing snapshot.
	pub fn bytes(&self) -> Option<&[u8]> {
		match self {
			Self::Directory { mode: _ } => Some(&[]),
			Self::File { mode: _, bytes } => Some(bytes),
			Self::Symlink { target } => Some(target),
			Self::FileAlias { mode: _, target: _ } => None,
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
impl Snapshot<'_> {
	/// Resolve one earlier-file alias. Invalid indices or chains return None;
	/// CanonicalSnapshot additionally validates the path and shared metadata.
	pub fn entry_bytes(&self, index: usize) -> Option<&[u8]> {
		match &self.entries.get(index)?.content {
			Content::FileAlias { target, mode: _ } => {
				if *target >= index {
					return None;
				}
				match &self.entries.get(*target)?.content {
					Content::File { bytes, mode: _ } => Some(bytes),
					Content::Directory { mode: _ }
					| Content::Symlink { target: _ }
					| Content::FileAlias { mode: _, target: _ } => None,
				}
			}
			content => content.bytes(),
		}
	}
}
