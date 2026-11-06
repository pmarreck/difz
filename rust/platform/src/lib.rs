//! Filesystem capabilities for Linux and macOS. Windows is not implemented yet.
#![cfg(any(target_os = "linux", target_os = "macos"))]
#![deny(unsafe_op_in_unsafe_fn)]
use std::io::Read;
use std::{
	fs::{File, OpenOptions},
	io,
	os::{
		fd::{AsRawFd, FromRawFd},
		unix::fs::OpenOptionsExt,
	},
	path::Path,
};

#[derive(Debug)]
pub enum Error {
	Io(io::Error),
	InvalidBasename,
	WrongKind,
	OutOfMemory,
	LimitExceeded,
}
impl From<io::Error> for Error {
	fn from(error: io::Error) -> Self {
		Self::Io(error)
	}
}

#[derive(Debug)]
pub struct Directory {
	file: File,
}
enum Child {
	Directory,
	RegularFile,
}
impl Directory {
	/// Open a root without following its final component. The returned handle
	/// pins directory identity independently of subsequent path renames.
	pub fn open(path: &Path) -> Result<Self, Error> {
		let file = OpenOptions::new()
			.read(true)
			.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
			.open(path)?;
		Ok(Self { file })
	}
	pub fn open_directory(&self, name: &[u8]) -> Result<Self, Error> {
		Ok(Self {
			file: self.open_child(name, Child::Directory)?,
		})
	}
	/// Reject symlinks and special files. Nonblocking open prevents a FIFO
	/// replacement from blocking before the opened descriptor can be classified.
	pub fn open_regular_file(&self, name: &[u8]) -> Result<File, Error> {
		self.open_child(name, Child::RegularFile)
	}
	/// Read at most maximum bytes from a no-follow regular file. Zero permits
	/// only an empty file. Work and output length are linear in retained bytes;
	/// the reader consumes at most one extra byte to detect an exceeded ceiling.
	pub fn read_file(&self, name: &[u8], maximum: usize) -> Result<Vec<u8>, Error> {
		read_limited(&mut self.open_regular_file(name)?, maximum)
	}
	fn open_child(&self, name: &[u8], kind: Child) -> Result<File, Error> {
		let terminated = basename(name)?;
		let extra = match kind {
			Child::Directory => libc::O_DIRECTORY,
			Child::RegularFile => libc::O_NONBLOCK,
		};
		// The borrowed parent descriptor stays live through this call. The
		// validated basename buffer contains exactly one trailing NUL and no
		// slash, so openat cannot traverse another parent or follow a symlink.
		let fd = unsafe {
			libc::openat(
				self.file.as_raw_fd(),
				terminated.as_ptr().cast(),
				libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | extra,
			)
		};
		if fd < 0 {
			return Err(io::Error::last_os_error().into());
		}
		// A successful openat returns a fresh owned descriptor. File now owns
		// its close on every success/error path; no other owner is constructed.
		let file = unsafe { File::from_raw_fd(fd) };
		let metadata = file.metadata()?;
		let valid = match kind {
			Child::Directory => metadata.is_dir(),
			Child::RegularFile => metadata.is_file(),
		};
		if !valid {
			return Err(Error::WrongKind);
		}
		Ok(file)
	}
}

fn basename(name: &[u8]) -> Result<Vec<u8>, Error> {
	difz_core::directory::validate_path(name).map_err(|_| Error::InvalidBasename)?;
	if name.contains(&b'/') {
		return Err(Error::InvalidBasename);
	}
	let mut terminated = Vec::new();
	terminated
		.try_reserve_exact(name.len() + 1)
		.map_err(|_| Error::OutOfMemory)?;
	terminated.extend_from_slice(name);
	terminated.push(0);
	Ok(terminated)
}

mod entry;
pub use entry::{EntryInfo, Identity, Kind};

fn read_limited(reader: &mut impl Read, maximum: usize) -> Result<Vec<u8>, Error> {
	let mut bytes = Vec::new();
	let mut buffer = [0u8; 65_536];
	loop {
		let remaining = maximum - bytes.len();
		let request = remaining.saturating_add(1).min(buffer.len());
		let count = match reader.read(&mut buffer[..request]) {
			Ok(count) => count,
			Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
			Err(error) => return Err(error.into()),
		};
		if count > request {
			return Err(io::Error::new(
				io::ErrorKind::InvalidData,
				"reader exceeded requested length",
			)
			.into());
		}
		if count == 0 {
			return Ok(bytes);
		}
		if count > remaining {
			return Err(Error::LimitExceeded);
		}
		bytes.try_reserve(count).map_err(|_| Error::OutOfMemory)?;
		bytes.extend_from_slice(&buffer[..count]);
	}
}
#[cfg(test)]
mod tests;

mod names;
pub use names::Names;
#[cfg(test)]
mod names_tests;
