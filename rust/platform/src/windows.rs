//! Read-only Windows capabilities. Child names resolve through the owned parent
//! handle, never through a reconstructed absolute path.
use crate::{Error, read_limited};
use std::{
	fs::{File, OpenOptions},
	io,
	os::windows::{
		fs::{MetadataExt, OpenOptionsExt},
		io::{AsRawHandle, FromRawHandle},
	},
	path::Path,
	ptr,
};
use windows_sys::{
	Wdk::{
		Foundation::OBJECT_ATTRIBUTES,
		Storage::FileSystem::{
			FILE_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT, FILE_SYNCHRONOUS_IO_NONALERT,
			NtCreateFile,
		},
	},
	Win32::{
		Foundation::{
			INVALID_HANDLE_VALUE, OBJ_CASE_INSENSITIVE, RtlNtStatusToDosError, UNICODE_STRING,
		},
		Storage::FileSystem::{
			FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
			FILE_GENERIC_READ, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
			FILE_TYPE_DISK, GetFileType,
		},
		System::IO::IO_STATUS_BLOCK,
	},
};

#[derive(Debug)]
pub struct Directory {
	file: File,
}
enum Child {
	Directory,
	RegularFile,
}
enum RelativeOpen<'a> {
	Child(&'a [u8]),
	CurrentDirectory,
}
impl Directory {
	/// Pin a directory without following its final component. As on Unix, the
	/// caller selects the root path; subsequent children use this opened root.
	pub fn open(path: &Path) -> Result<Self, Error> {
		let file = OpenOptions::new()
			.read(true)
			.share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
			.custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
			.open(path)?;
		check_kind(&file, Child::Directory)?;
		Ok(Self { file })
	}
	pub fn open_directory(&self, name: &[u8]) -> Result<Self, Error> {
		Ok(Self {
			file: self.open_child(name, Child::Directory)?,
		})
	}
	pub fn open_regular_file(&self, name: &[u8]) -> Result<File, Error> {
		self.open_child(name, Child::RegularFile)
	}
	/// Consume at most one byte beyond the caller's ceiling to detect overflow.
	/// The shared reader checks allocation failures and retains bounded output.
	pub fn read_file(&self, name: &[u8], maximum: usize) -> Result<Vec<u8>, Error> {
		read_limited(&mut self.open_regular_file(name)?, maximum)
	}
	fn open_child(&self, name: &[u8], kind: Child) -> Result<File, Error> {
		let file = self.open_child_handle(name)?;
		check_kind(&file, kind)?;
		Ok(file)
	}
	/// Open the entry itself, including a reparse point, for native inspection.
	fn open_child_handle(&self, name: &[u8]) -> Result<File, Error> {
		self.open_relative_handle(RelativeOpen::Child(name))
	}
	fn reopen_directory(&self) -> Result<File, Error> {
		self.open_relative_handle(RelativeOpen::CurrentDirectory)
	}
	fn open_relative_handle(&self, operation: RelativeOpen<'_>) -> Result<File, Error> {
		let (mut wide, kind_options) = match operation {
			RelativeOpen::CurrentDirectory => (Vec::new(), FILE_DIRECTORY_FILE),
			RelativeOpen::Child(name) => {
				difz_core::directory::validate_basename(name)
					.map_err(|_| Error::InvalidBasename)?;
				// A colon denotes an alternate data stream, not an ordinary child.
				if name.contains(&b':') {
					return Err(Error::InvalidBasename);
				}
				let text = std::str::from_utf8(name).map_err(|_| Error::InvalidBasename)?;
				let mut wide = Vec::new();
				wide.try_reserve_exact(name.len())
					.map_err(|_| Error::OutOfMemory)?;
				wide.extend(text.encode_utf16());
				(wide, 0)
			}
		};
		let bytes = wide
			.len()
			.checked_mul(2)
			.and_then(|n| u16::try_from(n).ok())
			.ok_or(Error::LimitExceeded)?;
		let mut unicode = UNICODE_STRING {
			Length: bytes,
			MaximumLength: bytes,
			Buffer: if wide.is_empty() {
				ptr::null_mut()
			} else {
				wide.as_mut_ptr()
			},
		};
		let attributes = OBJECT_ATTRIBUTES {
			Length: size_of::<OBJECT_ATTRIBUTES>() as u32,
			RootDirectory: self.file.as_raw_handle(),
			ObjectName: &mut unicode,
			Attributes: OBJ_CASE_INSENSITIVE,
			SecurityDescriptor: ptr::null_mut(),
			SecurityQualityOfService: ptr::null_mut(),
		};
		let mut handle = ptr::null_mut();
		let mut status_block = IO_STATUS_BLOCK::default();
		// The parent stays owned and live. The UTF-16 buffer and descriptor are
		// borrowed only during this synchronous call. No C-string terminator is
		// needed: UNICODE_STRING carries the exact byte length.
		let status = unsafe {
			NtCreateFile(
				&mut handle,
				FILE_GENERIC_READ,
				&attributes,
				&mut status_block,
				ptr::null(),
				0,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
				FILE_OPEN,
				FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT | kind_options,
				ptr::null(),
				0,
			)
		};
		if status < 0 {
			// This conversion neither consumes nor creates an OS handle.
			let code = unsafe { RtlNtStatusToDosError(status) };
			return Err(io::Error::from_raw_os_error(code as i32).into());
		}
		if handle.is_null() || handle == INVALID_HANDLE_VALUE {
			return Err(
				io::Error::new(io::ErrorKind::InvalidData, "invalid successful NT handle").into(),
			);
		}
		// A successful NtCreateFile returned a fresh owned handle. File owns
		// its close, including every metadata/kind error below.
		let file = unsafe { File::from_raw_handle(handle) };
		Ok(file)
	}
}

#[path = "windows_entry.rs"]
mod entry;
#[path = "windows_names.rs"]
mod names;
pub use names::Names;
#[path = "windows_link.rs"]
mod link;
#[path = "windows_text.rs"]
mod text;
fn check_kind(file: &File, kind: Child) -> Result<(), Error> {
	// The API borrows this live handle. Pipes and character devices do not
	// satisfy this filesystem capability even if another query accepts them.
	if unsafe { GetFileType(file.as_raw_handle()) } != FILE_TYPE_DISK {
		return Err(Error::WrongKind);
	}
	let metadata = file.metadata()?;
	if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return Err(Error::WrongKind);
	}
	let matches = match kind {
		Child::Directory => metadata.is_dir(),
		Child::RegularFile => metadata.is_file(),
	};
	if !matches {
		return Err(Error::WrongKind);
	}
	Ok(())
}

#[cfg(test)]
#[path = "windows_tests.rs"]
mod tests;
