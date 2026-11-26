use super::Directory;
use crate::{EntryInfo, Error, Identity, Kind};
use difz_core::{directory::Mode, metadata::Time};
use std::{fs::File, io, os::windows::io::AsRawHandle};
use windows_sys::Win32::{
	Foundation::FILETIME,
	Storage::FileSystem::{
		BY_HANDLE_FILE_INFORMATION, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
		FILE_ATTRIBUTE_TAG_INFO, FILE_ID_INFO, FILE_TYPE_DISK, FileAttributeTagInfo, FileIdInfo,
		GetFileInformationByHandle, GetFileInformationByHandleEx, GetFileType,
	},
	System::SystemServices::IO_REPARSE_TAG_SYMLINK,
};

impl Directory {
	pub fn inspect_self(&self) -> Result<EntryInfo, Error> {
		EntryInfo::for_file(&self.file)
	}
	/// Inspect the entry itself through the pinned parent. The handle prevents
	/// path replacement from redirecting queries; concurrent edits are not atomic.
	pub fn inspect(&self, name: &[u8]) -> Result<EntryInfo, Error> {
		EntryInfo::for_file(&self.open_child_handle(name)?)
	}
}
impl EntryInfo {
	pub fn for_file(file: &File) -> Result<Self, Error> {
		let handle = file.as_raw_handle();
		// Every query borrows the same live handle. All output records are
		// initialized integer-only SDK types of the exact advertised size.
		if unsafe { GetFileType(handle) } != FILE_TYPE_DISK {
			return Err(Error::WrongKind);
		}
		let mut basic = BY_HANDLE_FILE_INFORMATION::default();
		if unsafe { GetFileInformationByHandle(handle, &mut basic) } == 0 {
			return Err(io::Error::last_os_error().into());
		}
		let mut id = FILE_ID_INFO::default();
		// FILE_ID_INFO retains the full identifier, unlike the older 64-bit
		// file-index fields above. Never silently fall back to a narrowed ID.
		// https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info
		if unsafe {
			GetFileInformationByHandleEx(
				handle,
				FileIdInfo,
				(&mut id as *mut FILE_ID_INFO).cast(),
				size_of::<FILE_ID_INFO>() as u32,
			)
		} == 0
		{
			return Err(io::Error::last_os_error().into());
		}
		let kind = if basic.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			let mut tag = FILE_ATTRIBUTE_TAG_INFO::default();
			if unsafe {
				GetFileInformationByHandleEx(
					handle,
					FileAttributeTagInfo,
					(&mut tag as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
					size_of::<FILE_ATTRIBUTE_TAG_INFO>() as u32,
				)
			} == 0
			{
				return Err(io::Error::last_os_error().into());
			}
			let kind_bits = FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY;
			if (tag.FileAttributes ^ basic.dwFileAttributes) & kind_bits != 0 {
				return Err(
					io::Error::new(io::ErrorKind::InvalidData, "entry kind changed").into(),
				);
			}
			if tag.ReparseTag == IO_REPARSE_TAG_SYMLINK {
				Kind::Symlink
			} else {
				Kind::Other
			}
		} else if basic.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
			Kind::Directory
		} else {
			Kind::File
		};
		// Match the existing Windows tree contract's fixed portable modes.
		// These bits do not claim to represent the native DACL.
		let mode = match kind {
			Kind::Directory => 0o755,
			Kind::File => 0o644,
			Kind::Symlink => 0o777,
			Kind::Other => 0,
		};
		Ok(Self {
			kind,
			mode: Mode::from_bits(mode).map_err(|_| Error::WrongKind)?,
			length: (u64::from(basic.nFileSizeHigh) << 32) | u64::from(basic.nFileSizeLow),
			identity: identity(&id),
			mtime: timestamp(basic.ftLastWriteTime),
			birth: Some(timestamp(basic.ftCreationTime)),
			native_flags: 0,
		})
	}
}
fn identity(id: &FILE_ID_INFO) -> Identity {
	Identity {
		device: id.VolumeSerialNumber,
		inode: u128::from_le_bytes(id.FileId.Identifier),
	}
}
fn timestamp(time: FILETIME) -> Time {
	let ticks = (u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime);
	// Even u64::MAX ticks has fewer than 2^41 whole seconds, so conversion
	// and epoch subtraction fit i64. The remainder preserves 100ns precision,
	// including the fraction immediately before the Unix epoch.
	Time {
		sec: (ticks / 10_000_000) as i64 - 11_644_473_600,
		nsec: ((ticks % 10_000_000) * 100) as u32,
	}
}

#[cfg(test)]
#[path = "windows_entry_tests.rs"]
mod tests;
