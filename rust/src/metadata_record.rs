use super::{AceTag, AclOrigin, Error, Time, XattrClass};
use alloc::{borrow::Cow, vec::Vec};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Permissions(u8);
impl Permissions {
	pub const READ: Self = Self(1);
	pub const WRITE: Self = Self(2);
	pub const EXECUTE: Self = Self(4);
	pub fn from_bits(bits: u8) -> Result<Self, Error> {
		let known = Self::READ.0 | Self::WRITE.0 | Self::EXECUTE.0;
		if bits & !known != 0 {
			return Err(Error::BadMetadata);
		}
		Ok(Self(bits))
	}
	pub const fn bits(self) -> u8 {
		self.0
	}
	pub const fn contains(self, permission: Self) -> bool {
		self.0 & permission.0 == permission.0
	}
}

#[derive(Debug, Eq, PartialEq)]
pub struct Xattr<'a> {
	pub class: XattrClass,
	pub name: Cow<'a, [u8]>,
	pub value: Cow<'a, [u8]>,
}
#[derive(Debug, Eq, PartialEq)]
pub struct Ace<'a> {
	pub tag: AceTag,
	pub permissions: Permissions,
	pub name: Cow<'a, [u8]>,
}
#[derive(Debug, Eq, PartialEq)]
pub struct NativeAcl<'a> {
	pub origin: AclOrigin,
	pub bytes: Cow<'a, [u8]>,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Times {
	pub mtime: Option<Time>,
	pub atime: Option<Time>,
	pub btime: Option<Time>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Hole {
	pub offset: u64,
	pub length: u64,
}

/// An unvalidated record. Descriptor vectors own their storage; byte fields
/// can borrow encoded input or own captured filesystem data. This type alone
/// does not authorize canonical encoding, hashing or filesystem restoration.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct Metadata<'a> {
	pub xattrs: Vec<Xattr<'a>>,
	pub aces: Vec<Ace<'a>>,
	pub native_acl: Option<NativeAcl<'a>>,
	pub times: Times,
	pub finder_flags: u32,
	pub finder_info: Option<[u8; 32]>,
	pub holes: Vec<Hole>,
	pub hardlink_to: Option<Cow<'a, [u8]>>,
}
impl Metadata<'_> {
	pub fn is_empty(&self) -> bool {
		let Self {
			xattrs,
			aces,
			native_acl,
			times,
			finder_flags,
			finder_info,
			holes,
			hardlink_to,
		} = self;
		xattrs.is_empty()
			&& aces.is_empty()
			&& native_acl.is_none()
			&& *times == Times::default()
			&& *finder_flags == 0
			&& finder_info.is_none()
			&& holes.is_empty()
			&& hardlink_to.is_none()
	}
}
