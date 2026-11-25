//! Linux raw attribute reads through live file descriptors.
use super::Error;
use std::{fs::File, io, os::fd::AsRawFd};

/// Bounded native reads shared by opened objects and no-follow symlinks.
pub trait ReadAttributes {
	fn get(&self, name: &[u8], maximum: usize) -> Result<Option<Vec<u8>>, Error>;
	fn list(&self, maximum_bytes: usize, maximum_count: usize) -> Result<Names, Error>;
}
impl ReadAttributes for File {
	fn get(&self, name: &[u8], maximum: usize) -> Result<Option<Vec<u8>>, Error> {
		get(self, name, maximum)
	}
	fn list(&self, maximum_bytes: usize, maximum_count: usize) -> Result<Names, Error> {
		list(self, maximum_bytes, maximum_count)
	}
}

/// Linux lacks descriptor-relative lgetxattr. A procfs path pins its parent
/// through the borrowed descriptor; l* calls do not follow the final link.
/// Recheck identity on every read. Concurrent mutation is not an atomic scan.
pub struct Symlink<'a> {
	parent: &'a super::Directory,
	path: Vec<u8>,
	name_offset: usize,
	info: super::EntryInfo,
}
impl<'a> Symlink<'a> {
	pub fn open(parent: &'a super::Directory, name: &[u8]) -> Result<Self, Error> {
		let info = parent.inspect(name)?;
		if info.kind != super::Kind::Symlink {
			return Err(Error::WrongKind);
		}
		let mut path = Vec::new();
		path.try_reserve_exact(name.len().checked_add(32).ok_or(Error::LimitExceeded)?)
			.map_err(|_| Error::OutOfMemory)?;
		// The 32-byte allowance covers the prefix, signed-int descriptor and
		// terminator. Formatting cannot need another allocation in this buffer.
		use std::io::Write;
		write!(&mut path, "/proc/self/fd/{}/", parent.file.as_raw_fd())?;
		let name_offset = path.len();
		path.extend_from_slice(name);
		path.push(0);
		let reader = Self {
			parent,
			path,
			name_offset,
			info,
		};
		reader.verify()?;
		Ok(reader)
	}
	pub fn info(&self) -> super::EntryInfo {
		self.info
	}
	pub fn verify(&self) -> Result<(), Error> {
		if self
			.parent
			.inspect(&self.path[self.name_offset..self.path.len() - 1])?
			!= self.info
		{
			return Err(invalid_data("symlink changed during attribute capture"));
		}
		Ok(())
	}
	/// Write the link itself, preserving a target object's attributes. The
	/// caller owns the new staging link; permission/unsupported errors may be
	/// represented later by its parent transport.
	pub fn set(&self, name: &[u8], value: &[u8]) -> Result<(), Error> {
		self.verify()?;
		let name = terminated_name(name)?;
		// Borrowed pinned parent, terminated names and explicit value length.
		// lsetxattr never follows the final symbolic link to its target.
		let result = unsafe {
			libc::lsetxattr(
				self.path.as_ptr().cast(),
				name.as_ptr().cast(),
				value.as_ptr().cast(),
				value.len(),
				0,
			)
		};
		let error = if result < 0 {
			Some(io::Error::last_os_error())
		} else {
			None
		};
		self.verify()?;
		if let Some(error) = error {
			return Err(error.into());
		}
		Ok(())
	}
}
impl ReadAttributes for Symlink<'_> {
	fn get(&self, name: &[u8], maximum: usize) -> Result<Option<Vec<u8>>, Error> {
		self.verify()?;
		let name = terminated_name(name)?;
		let result = read_buffer(maximum, |output| {
			// The parent borrow pins the descriptor in this terminated procfs
			// path. lgetxattr reads the final symlink itself, including dangling
			// links. The kernel writes only the initialized explicit-length buffer.
			count(unsafe {
				libc::lgetxattr(
					self.path.as_ptr().cast(),
					name.as_ptr().cast(),
					output.as_mut_ptr().cast(),
					output.len(),
				)
			})
		});
		self.verify()?;
		match result {
			Ok(bytes) => Ok(Some(bytes)),
			Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENODATA) => Ok(None),
			Err(error) => Err(error),
		}
	}
	fn list(&self, maximum_bytes: usize, maximum_count: usize) -> Result<Names, Error> {
		self.verify()?;
		let bytes = read_buffer(maximum_bytes, |output| {
			// Same pinned, terminated path contract as get; llistxattr never
			// follows its final component to the symbolic link's target.
			count(unsafe {
				libc::llistxattr(
					self.path.as_ptr().cast(),
					output.as_mut_ptr().cast(),
					output.len(),
				)
			})
		})?;
		self.verify()?;
		Names::parse(bytes, maximum_count)
	}
}

#[derive(Debug)]
pub struct Names(Vec<u8>);
impl Names {
	fn parse(bytes: Vec<u8>, maximum_count: usize) -> Result<Self, Error> {
		if !bytes.is_empty() && bytes.last() != Some(&0) {
			return Err(invalid_data("unterminated attribute list"));
		}
		let mut remaining = maximum_count;
		for name in bytes.split_inclusive(|byte| *byte == 0) {
			if name.len() <= 1 || name.len() > 256 {
				return Err(invalid_data("invalid attribute name length"));
			}
			if remaining == 0 {
				return Err(Error::LimitExceeded);
			}
			remaining -= 1;
		}
		Ok(Self(bytes))
	}
	pub fn iter(&self) -> impl Iterator<Item = &[u8]> {
		self.0
			.split_inclusive(|byte| *byte == 0)
			.map(|name| &name[..name.len() - 1])
	}
}
/// ENODATA means absent or inaccessible according to the kernel. Unsupported
/// filesystems and other OS failures remain explicit IO errors.
pub fn get(file: &File, name: &[u8], maximum: usize) -> Result<Option<Vec<u8>>, Error> {
	let terminated = terminated_name(name)?;
	let result = read_buffer(maximum, |output| {
		// The descriptor is borrowed from a live File, the name is terminated,
		// and value storage is initialized and writable for the explicit length.
		count(unsafe {
			libc::fgetxattr(
				file.as_raw_fd(),
				terminated.as_ptr().cast(),
				output.as_mut_ptr().cast(),
				output.len(),
			)
		})
	});
	match result {
		Ok(bytes) => Ok(Some(bytes)),
		Err(Error::Io(error)) if error.raw_os_error() == Some(libc::ENODATA) => Ok(None),
		Err(error) => Err(error),
	}
}
/// Create or replace a raw attribute on the object owned by the open handle.
/// Values have an explicit byte length and may be empty or contain NUL.
pub fn set(file: &File, name: &[u8], value: &[u8]) -> Result<(), Error> {
	let name = terminated_name(name)?;
	// All buffers and the borrowed descriptor remain live. The kernel copies
	// exactly value.len() bytes and does not retain these pointers.
	let result = unsafe {
		libc::fsetxattr(
			file.as_raw_fd(),
			name.as_ptr().cast(),
			value.as_ptr().cast(),
			value.len(),
			0,
		)
	};
	if result < 0 {
		return Err(io::Error::last_os_error().into());
	}
	Ok(())
}
/// Remove a raw attribute. False means the kernel reported it absent.
pub fn remove(file: &File, name: &[u8]) -> Result<bool, Error> {
	let name = terminated_name(name)?;
	// The descriptor and terminated name are live for this synchronous call.
	let result = unsafe { libc::fremovexattr(file.as_raw_fd(), name.as_ptr().cast()) };
	if result == 0 {
		return Ok(true);
	}
	let error = io::Error::last_os_error();
	if error.raw_os_error() == Some(libc::ENODATA) {
		Ok(false)
	} else {
		Err(error.into())
	}
}
fn terminated_name(name: &[u8]) -> Result<Vec<u8>, Error> {
	if name.is_empty() || name.len() > 255 || name.contains(&0) {
		return Err(Error::InvalidAttributeName);
	}
	let mut terminated = Vec::new();
	terminated
		.try_reserve_exact(name.len() + 1)
		.map_err(|_| Error::OutOfMemory)?;
	terminated.extend_from_slice(name);
	terminated.push(0);
	Ok(terminated)
}
/// List the kernel-visible raw names. Each name still includes its native
/// namespace prefix; canonical classification belongs to metadata capture.
pub fn list(file: &File, maximum_bytes: usize, maximum_count: usize) -> Result<Names, Error> {
	let bytes = read_buffer(maximum_bytes, |output| {
		// Live borrowed descriptor and initialized writable output buffer.
		count(unsafe {
			libc::flistxattr(file.as_raw_fd(), output.as_mut_ptr().cast(), output.len())
		})
	})?;
	Names::parse(bytes, maximum_count)
}
fn read_buffer(
	maximum: usize,
	mut read: impl FnMut(&mut [u8]) -> io::Result<usize>,
) -> Result<Vec<u8>, Error> {
	let ceiling = maximum.checked_add(1).ok_or(Error::LimitExceeded)?;
	let mut capacity = 256.min(ceiling);
	loop {
		let mut bytes = Vec::new();
		bytes
			.try_reserve_exact(capacity)
			.map_err(|_| Error::OutOfMemory)?;
		bytes.resize(capacity, 0);
		let count = match read(&mut bytes) {
			Ok(count) => count,
			Err(error) if error.raw_os_error() == Some(libc::ERANGE) => {
				if capacity == ceiling {
					return Err(Error::LimitExceeded);
				}
				capacity = capacity.saturating_mul(2).min(ceiling);
				continue;
			}
			Err(error) => return Err(error.into()),
		};
		if count > capacity {
			return Err(invalid_data("attribute reader exceeded capacity"));
		}
		if count > maximum {
			return Err(Error::LimitExceeded);
		}
		// Unlike readlink, a successful xattr call returns the complete value;
		// insufficient buffers return ERANGE, including under concurrent growth.
		// https://man7.org/linux/man-pages/man2/getxattr.2.html
		bytes.truncate(count);
		return Ok(bytes);
	}
}
fn count(result: libc::ssize_t) -> io::Result<usize> {
	if result < 0 {
		Err(io::Error::last_os_error())
	} else {
		Ok(result as usize)
	}
}
fn invalid_data(message: &'static str) -> Error {
	io::Error::new(io::ErrorKind::InvalidData, message).into()
}
#[cfg(test)]
#[path = "xattr_tests.rs"]
mod tests;
