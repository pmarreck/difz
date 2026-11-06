use super::{Directory, Error};
use std::{
	ffi::CStr,
	fs::File,
	io,
	os::fd::{AsRawFd, FromRawFd, IntoRawFd},
	ptr::NonNull,
};

/// An owned, independent directory stream. Raw names exclude dot entries;
/// the caller validates format paths and inspects each child's actual kind.
/// Concurrent filesystem mutation does not produce an atomic snapshot.
#[derive(Debug)]
pub struct Names {
	stream: NonNull<libc::DIR>,
	remaining: usize,
	maximum_name_bytes: usize,
	finished: bool,
}
impl Directory {
	pub fn names(&self, maximum_entries: usize, maximum_name_bytes: usize) -> Result<Names, Error> {
		// Reopen the pinned directory itself, rather than duplicating a
		// descriptor whose enumeration offset would be shared by other streams.
		let descriptor = unsafe {
			libc::openat(
				self.file.as_raw_fd(),
				c".".as_ptr(),
				libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
			)
		};
		if descriptor < 0 {
			return Err(io::Error::last_os_error().into());
		}
		// openat returned a fresh descriptor; File owns all failure paths.
		let file = unsafe { File::from_raw_fd(descriptor) };
		// fdopendir takes descriptor ownership only on success. No other
		// operation accesses it before transfer into the directory owner.
		let stream = unsafe { libc::fdopendir(file.as_raw_fd()) };
		let stream = NonNull::new(stream).ok_or_else(io::Error::last_os_error)?;
		let _ = file.into_raw_fd();
		Ok(Names {
			stream,
			remaining: maximum_entries,
			maximum_name_bytes,
			finished: false,
		})
	}
}
impl Iterator for Names {
	type Item = Result<Vec<u8>, Error>;
	fn next(&mut self) -> Option<Self::Item> {
		if self.finished {
			return None;
		}
		// Every exit except a yielded name finishes the stream, including
		// allocation/limit errors. Retrying cannot silently skip a failed entry.
		self.finished = true;
		loop {
			// POSIX distinguishes end-of-stream from error only through errno.
			// This thread owns the errno cell; the live DIR is exclusively borrowed
			// by this call. Read errno before any other library call can change it.
			let (entry, error) = unsafe {
				let cell = errno_address();
				*cell = 0;
				let entry = libc::readdir(self.stream.as_ptr());
				(entry, *cell)
			};
			if entry.is_null() {
				return if error == 0 {
					None
				} else {
					Some(Err(io::Error::from_raw_os_error(error).into()))
				};
			}
			// readdir guarantees a terminated d_name, valid until the next call.
			// Do not form a reference to the whole variable-length dirent or rely
			// on libc's declared d_name array length. Copy before advancing.
			// https://man7.org/linux/man-pages/man3/readdir.3.html
			let name =
				unsafe { CStr::from_ptr(std::ptr::addr_of!((*entry).d_name).cast()) }.to_bytes();
			if name == b"." || name == b".." {
				continue;
			}
			if self.remaining == 0 || name.len() > self.maximum_name_bytes {
				return Some(Err(Error::LimitExceeded));
			}
			let mut bytes = Vec::new();
			if bytes.try_reserve_exact(name.len()).is_err() {
				return Some(Err(Error::OutOfMemory));
			}
			bytes.extend_from_slice(name);
			self.remaining -= 1;
			self.finished = false;
			return Some(Ok(bytes));
		}
	}
}
impl std::iter::FusedIterator for Names {}
impl Drop for Names {
	fn drop(&mut self) {
		// This owner closes its stream and underlying descriptor exactly once.
		unsafe {
			libc::closedir(self.stream.as_ptr());
		}
	}
}
fn errno_address() -> *mut libc::c_int {
	// The supported libc exposes a nonnull writable cell for this thread.
	#[cfg(target_os = "linux")]
	unsafe {
		libc::__errno_location()
	}
	#[cfg(target_os = "macos")]
	unsafe {
		libc::__error()
	}
}
