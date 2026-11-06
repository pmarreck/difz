use super::{Directory, Error, basename};
use difz_core::directory::Mode;
use difz_core::metadata::Time;
use std::{ffi::CStr, fs::File};
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
	/// Native modification time, before applying timestamp transport records.
	pub mtime: Time,
	/// Absent when the OS/filesystem does not report creation time.
	pub birth: Option<Time>,
	/// Raw Darwin flags; zero on Linux, whose Finder data uses transport.
	pub native_flags: u32,
}
impl EntryInfo {
	/// Inspect the object owned by the handle, independent of its current path.
	pub fn for_file(file: &File) -> Result<Self, Error> {
		query(file, None)
	}
}
impl Directory {
	pub fn inspect_self(&self) -> Result<EntryInfo, Error> {
		EntryInfo::for_file(&self.file)
	}
	/// Observe the named entry itself through the pinned parent. This is not
	/// a transaction with subsequent opens, which recheck their actual kind.
	pub fn inspect(&self, name: &[u8]) -> Result<EntryInfo, Error> {
		let name = basename(name)?;
		let name = CStr::from_bytes_with_nul(&name).map_err(|_| Error::InvalidBasename)?;
		query(&self.file, Some(name))
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

fn invalid_data(message: &'static str) -> Error {
	io::Error::new(io::ErrorKind::InvalidData, message).into()
}
fn stamp(sec: i64, nsec: i64) -> Result<Time, Error> {
	if !(0..1_000_000_000).contains(&nsec) {
		return Err(invalid_data("invalid native timestamp"));
	}
	Ok(Time {
		sec,
		nsec: nsec as u32,
	})
}
fn finish(
	mode: u32,
	length: u64,
	identity: Identity,
	mtime: Time,
	birth: Option<Time>,
	native_flags: u32,
) -> Result<EntryInfo, Error> {
	const FILE: u32 = libc::S_IFREG as u32;
	const DIRECTORY: u32 = libc::S_IFDIR as u32;
	const SYMLINK: u32 = libc::S_IFLNK as u32;
	let kind = match mode & libc::S_IFMT as u32 {
		FILE => Kind::File,
		DIRECTORY => Kind::Directory,
		SYMLINK => Kind::Symlink,
		_ => Kind::Other,
	};
	let bits = if kind == Kind::Symlink {
		0o777
	} else {
		(mode & 0o777) as u16
	};
	let mode = Mode::from_bits(bits).map_err(|_| invalid_data("invalid portable mode"))?;
	Ok(EntryInfo {
		kind,
		mode,
		length,
		identity,
		mtime,
		birth,
		native_flags,
	})
}

#[cfg(target_os = "linux")]
const REQUIRED: u32 =
	libc::STATX_TYPE | libc::STATX_MODE | libc::STATX_INO | libc::STATX_SIZE | libc::STATX_MTIME;
#[cfg(target_os = "linux")]
fn query(file: &File, name: Option<&CStr>) -> Result<EntryInfo, Error> {
	let (name, flags) = match name {
		Some(name) => (name, libc::AT_SYMLINK_NOFOLLOW | libc::AT_NO_AUTOMOUNT),
		None => (c"", libc::AT_EMPTY_PATH),
	};
	let mut storage = MaybeUninit::<libc::statx>::zeroed();
	// Live descriptor, terminated pathname and aligned initialized output.
	// One syscall obtains identity and timestamps from the selected object.
	let result = unsafe {
		libc::statx(
			file.as_raw_fd(),
			name.as_ptr(),
			flags,
			REQUIRED | libc::STATX_BTIME,
			storage.as_mut_ptr(),
		)
	};
	if result != 0 {
		return Err(io::Error::last_os_error().into());
	}
	// Successful statx filled the integer-only initialized object.
	let stat = unsafe { storage.assume_init() };
	from_statx(&stat)
}
#[cfg(target_os = "linux")]
fn from_statx(stat: &libc::statx) -> Result<EntryInfo, Error> {
	if stat.stx_mask & REQUIRED != REQUIRED {
		return Err(invalid_data("missing required native metadata"));
	}
	let birth = if stat.stx_mask & libc::STATX_BTIME != 0 {
		Some(stamp(
			stat.stx_btime.tv_sec,
			i64::from(stat.stx_btime.tv_nsec),
		)?)
	} else {
		None
	};
	finish(
		u32::from(stat.stx_mode),
		stat.stx_size,
		Identity {
			device: libc::makedev(stat.stx_dev_major, stat.stx_dev_minor),
			inode: stat.stx_ino,
		},
		stamp(stat.stx_mtime.tv_sec, i64::from(stat.stx_mtime.tv_nsec))?,
		birth,
		0,
	)
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
	use super::*;
	#[test]
	fn statx_masks_and_nanoseconds_reject_missing_or_invalid_fields() {
		// This libc record contains only integers and integer padding; zero
		// initialization is valid and tests explicit kernel-response masks.
		let mut stat = unsafe { MaybeUninit::<libc::statx>::zeroed().assume_init() };
		stat.stx_mask = REQUIRED;
		stat.stx_mode = (libc::S_IFREG | 0o640) as u16;
		stat.stx_size = 7;
		stat.stx_ino = 42;
		stat.stx_mtime.tv_sec = -5;
		stat.stx_mtime.tv_nsec = 6;
		// Unreported birth storage is ignored even when its bytes are invalid.
		stat.stx_btime.tv_nsec = 1_000_000_000;
		let info = from_statx(&stat).unwrap();
		assert_eq!(info.mtime, Time { sec: -5, nsec: 6 });
		assert_eq!(info.birth, None);
		assert_eq!(info.length, 7);
		assert_eq!(info.identity.inode, 42);
		assert_eq!(info.mode.bits(), 0o640);
		for missing in [
			libc::STATX_TYPE,
			libc::STATX_MODE,
			libc::STATX_INO,
			libc::STATX_SIZE,
			libc::STATX_MTIME,
		] {
			stat.stx_mask = REQUIRED & !missing;
			assert!(from_statx(&stat).is_err());
		}
		stat.stx_mask = REQUIRED | libc::STATX_BTIME;
		assert!(from_statx(&stat).is_err());
		stat.stx_btime.tv_nsec = 0;
		assert_eq!(
			from_statx(&stat).unwrap().birth,
			Some(Time { sec: 0, nsec: 0 })
		);
		stat.stx_mtime.tv_nsec = 1_000_000_000;
		assert!(from_statx(&stat).is_err());
	}
}
#[cfg(target_os = "macos")]
fn query(file: &File, name: Option<&CStr>) -> Result<EntryInfo, Error> {
	let mut storage = MaybeUninit::<libc::stat>::zeroed();
	// Live descriptor, optional terminated basename and aligned output.
	let result = unsafe {
		match name {
			Some(name) => libc::fstatat(
				file.as_raw_fd(),
				name.as_ptr(),
				storage.as_mut_ptr(),
				libc::AT_SYMLINK_NOFOLLOW,
			),
			None => libc::fstat(file.as_raw_fd(), storage.as_mut_ptr()),
		}
	};
	if result != 0 {
		return Err(io::Error::last_os_error().into());
	}
	// Successful syscall filled the initialized integer-only stat storage.
	let stat = unsafe { storage.assume_init() };
	let length = u64::try_from(stat.st_size).map_err(|_| invalid_data("negative entry length"))?;
	finish(
		u32::from(stat.st_mode),
		length,
		Identity {
			device: stat.st_dev as u64,
			inode: stat.st_ino,
		},
		stamp(stat.st_mtime, stat.st_mtime_nsec)?,
		Some(stamp(stat.st_birthtime, stat.st_birthtime_nsec)?),
		stat.st_flags,
	)
}
