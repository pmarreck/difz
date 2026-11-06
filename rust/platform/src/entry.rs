use super::{Directory, Error, basename};
use difz_core::directory::Mode;
use std::{io, mem::MaybeUninit, os::fd::AsRawFd};

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
	pub inode: u64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EntryInfo {
	pub kind: Kind,
	pub mode: Mode,
	pub length: u64,
	pub identity: Identity,
}
impl Directory {
	/// Observe the named entry itself through the pinned parent. This is not
	/// a transaction with subsequent opens, which recheck their actual kind.
	pub fn inspect(&self, name: &[u8]) -> Result<EntryInfo, Error> {
		let name = basename(name)?;
		let mut storage = MaybeUninit::<libc::stat>::zeroed();
		// Parent and terminated basename remain live. The output points to a
		// correctly aligned complete stat object; all integer fields start zero.
		let result = unsafe {
			libc::fstatat(
				self.file.as_raw_fd(),
				name.as_ptr().cast(),
				storage.as_mut_ptr(),
				libc::AT_SYMLINK_NOFOLLOW,
			)
		};
		if result != 0 {
			return Err(io::Error::last_os_error().into());
		}
		// The successful syscall populated the initialized stat storage.
		let stat = unsafe { storage.assume_init() };
		let kind = match stat.st_mode & libc::S_IFMT {
			libc::S_IFREG => Kind::File,
			libc::S_IFDIR => Kind::Directory,
			libc::S_IFLNK => Kind::Symlink,
			_ => Kind::Other,
		};
		let bits = if kind == Kind::Symlink {
			0o777
		} else {
			(u32::from(stat.st_mode) & 0o777) as u16
		};
		let mode = Mode::from_bits(bits)
			.map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid portable mode"))?;
		let length = u64::try_from(stat.st_size)
			.map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "negative entry length"))?;
		Ok(EntryInfo {
			kind,
			mode,
			length,
			identity: Identity {
				device: stat.st_dev as u64,
				inode: stat.st_ino as u64,
			},
		})
	}
	/// Read raw link bytes with a caller ceiling. The extra byte distinguishes
	/// a complete result at the ceiling from truncation; no size hint is trusted.
	pub fn read_symlink(&self, name: &[u8], maximum: usize) -> Result<Vec<u8>, Error> {
		let name = basename(name)?;
		let ceiling = maximum.checked_add(1).ok_or(Error::LimitExceeded)?;
		let mut capacity = 256.min(ceiling);
		loop {
			let mut bytes = Vec::new();
			bytes
				.try_reserve_exact(capacity)
				.map_err(|_| Error::OutOfMemory)?;
			bytes.resize(capacity, 0);
			// readlinkat writes into this initialized writable buffer, relative
			// to the live parent, and returns a length without appending NUL.
			// https://man7.org/linux/man-pages/man2/readlink.2.html
			let count = unsafe {
				libc::readlinkat(
					self.file.as_raw_fd(),
					name.as_ptr().cast(),
					bytes.as_mut_ptr().cast(),
					bytes.len(),
				)
			};
			if count < 0 {
				return Err(io::Error::last_os_error().into());
			}
			let count = count as usize;
			if count > capacity {
				return Err(io::Error::new(
					io::ErrorKind::InvalidData,
					"link reader exceeded capacity",
				)
				.into());
			}
			if count > maximum {
				return Err(Error::LimitExceeded);
			}
			if count < capacity {
				bytes.truncate(count);
				return Ok(bytes);
			}
			capacity = capacity.saturating_mul(2).min(ceiling);
		}
	}
}
