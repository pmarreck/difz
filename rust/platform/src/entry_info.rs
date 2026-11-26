use difz_core::{directory::Mode, metadata::Time};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
	File,
	Directory,
	Symlink,
	Other,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct Identity {
	pub device: u64,
	/// Preserve Windows' complete 128-bit file ID. Unix inode numbers widen
	/// losslessly; this identity is not part of the serialized tree format.
	pub inode: u128,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EntryInfo {
	pub kind: Kind,
	pub mode: Mode,
	pub length: u64,
	pub identity: Identity,
	/// Native modification time, before applying timestamp transport records.
	pub mtime: Time,
	/// Absent when the OS/filesystem does not report creation time.
	pub birth: Option<Time>,
	/// Raw Darwin flags; zero on other platforms, which use transport.
	pub native_flags: u32,
}
