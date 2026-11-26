use super::Directory;
use crate::Error;
use std::{io, mem::size_of_val, os::windows::io::AsRawHandle, ptr};
use windows_sys::Win32::System::{
	IO::DeviceIoControl,
	Ioctl::FSCTL_GET_REPARSE_POINT,
	SystemServices::{IO_REPARSE_TAG_MOUNT_POINT, IO_REPARSE_TAG_SYMLINK},
};

#[derive(Clone, Copy)]
pub(super) enum LinkKind {
	SymbolicLink,
	Junction,
}
pub(super) fn kind(tag: u32) -> Option<LinkKind> {
	match tag {
		IO_REPARSE_TAG_SYMLINK => Some(LinkKind::SymbolicLink),
		IO_REPARSE_TAG_MOUNT_POINT => Some(LinkKind::Junction),
		_ => None,
	}
}
impl Directory {
	/// Read the reparse object through the pinned parent, without opening its
	/// destination. The byte ceiling applies after native path normalization.
	pub fn read_symlink(&self, name: &[u8], maximum: usize) -> Result<Vec<u8>, Error> {
		let file = self.open_child_handle(name)?;
		// Windows caps the complete reparse record at16KiB. The initialized
		// integer array supplies aligned writable storage, with no heap growth.
		let mut words = [0u64; 2048];
		let mut returned = 0;
		// The owned synchronous no-follow handle and output/status slots remain
		// live. No callback or retained buffer pointer crosses this call.
		if unsafe {
			DeviceIoControl(
				file.as_raw_handle(),
				FSCTL_GET_REPARSE_POINT,
				ptr::null(),
				0,
				words.as_mut_ptr().cast(),
				size_of_val(&words) as u32,
				&mut returned,
				ptr::null_mut(),
			)
		} == 0
		{
			return Err(io::Error::last_os_error().into());
		}
		if returned as usize > size_of_val(&words) {
			return Err(invalid("reparse result exceeds buffer"));
		}
		// All words are initialized; the exclusive FFI borrow has ended. Only
		// the OS-reported extent is exposed, and the decoder borrows it locally.
		let bytes = unsafe { std::slice::from_raw_parts(words.as_ptr().cast(), returned as usize) };
		decode(bytes, maximum)
	}
}
fn invalid(message: &'static str) -> Error {
	io::Error::new(io::ErrorKind::InvalidData, message).into()
}
fn u16_at(bytes: &[u8], at: usize) -> u16 {
	u16::from_le_bytes([bytes[at], bytes[at + 1]])
}
fn u32_at(bytes: &[u8], at: usize) -> u32 {
	u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}
fn extent(bytes: &[u8], offset: u16, length: u16) -> Result<&[u8], Error> {
	if offset % 2 != 0 || length % 2 != 0 {
		return Err(invalid("unaligned reparse string"));
	}
	let end = usize::from(offset) + usize::from(length);
	bytes
		.get(usize::from(offset)..end)
		.ok_or_else(|| invalid("reparse string exceeds record"))
}
fn decode(record: &[u8], maximum: usize) -> Result<Vec<u8>, Error> {
	if record.len() < 8 {
		return Err(invalid("truncated reparse header"));
	}
	let tag = kind(u32_at(record, 0)).ok_or(Error::WrongKind)?;
	let data_end = 8 + usize::from(u16_at(record, 4));
	let data = record
		.get(8..data_end)
		.ok_or_else(|| invalid("truncated reparse data"))?;
	let (fixed, relative) = match tag {
		LinkKind::SymbolicLink => {
			if data.len() < 12 {
				return Err(invalid("truncated symbolic link fields"));
			}
			let flags = u32_at(data, 8);
			if flags & !1 != 0 {
				return Err(invalid("unknown symbolic link flags"));
			}
			(12, flags & 1 != 0)
		}
		LinkKind::Junction => {
			if data.len() < 8 {
				return Err(invalid("truncated junction fields"));
			}
			(8, false)
		}
	};
	let paths = &data[fixed..];
	if paths.len() % 2 != 0 {
		return Err(invalid("unaligned reparse paths"));
	}
	let substitute = extent(paths, u16_at(data, 0), u16_at(data, 2))?;
	// Validate even the unused display-name extent. It must never override
	// the substitute target that the filesystem actually resolves.
	let _ = extent(paths, u16_at(data, 4), u16_at(data, 6))?;
	if substitute.is_empty() {
		return Err(invalid("empty substitute target"));
	}
	normalize(substitute, relative, maximum)
}
fn normalize(mut path: &[u8], relative: bool, maximum: usize) -> Result<Vec<u8>, Error> {
	let mut prefix = "";
	// Match the existing Zig ntToWin32Namespace contract. The NT prefix is
	// exactly backslash-??-backslash, while UNC accepts either final separator.
	if !relative && path.starts_with(&[b'\\', 0, b'?', 0, b'?', 0, b'\\', 0]) {
		path = &path[8..];
		if path.len() >= 8
			&& path[..6]
				.chunks_exact(2)
				.zip(b"UNC")
				.all(|(pair, expected)| pair[1] == 0 && pair[0].to_ascii_uppercase() == *expected)
			&& path[7] == 0
			&& matches!(path[6], b'\\' | b'/')
		{
			prefix = "\\";
			path = &path[6..];
		}
	}
	let result = super::text::decode(path, maximum, prefix, || {
		invalid("invalid UTF-16 link target")
	})?;
	if result.is_empty() {
		return Err(invalid("empty normalized target"));
	}
	Ok(result)
}

#[cfg(test)]
#[path = "windows_link_tests.rs"]
mod tests;
