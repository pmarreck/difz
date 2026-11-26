use super::{Child, Directory, check_kind};
use crate::{EntryInfo, Error};
use std::{fs::File, io, os::windows::io::AsRawHandle, ptr};
use windows_sys::{
	Wdk::Storage::FileSystem::{FileNamesInformation, NtQueryDirectoryFile},
	Win32::{
		Foundation::{
			RtlNtStatusToDosError, STATUS_BUFFER_OVERFLOW, STATUS_NO_MORE_FILES, STATUS_SUCCESS,
		},
		System::IO::IO_STATUS_BLOCK,
	},
};

/// Independent kernel enumeration position and a fixed-size aligned batch.
/// Errors finish the stream; retrying cannot silently skip a rejected name.
#[derive(Debug)]
pub struct Names {
	file: File,
	buffer: Vec<u64>,
	used: usize,
	offset: usize,
	remaining: usize,
	maximum_name_bytes: usize,
	restart: bool,
	finished: bool,
}
impl Directory {
	pub fn names(&self, maximum_entries: usize, maximum_name_bytes: usize) -> Result<Names, Error> {
		// Reopen the actual object, without reconstructing its path or sharing
		// a duplicated handle's directory position. Neither handle is inherited.
		// An empty relative NT name reopens this object. FILE_DIRECTORY_FILE
		// matters: Wine's ReOpenFile wrapper always requests
		// FILE_NON_DIRECTORY_FILE, even with FILE_FLAG_BACKUP_SEMANTICS.
		let file = self.reopen_directory()?;
		check_kind(&file, Child::Directory)?;
		if EntryInfo::for_file(&file)?.identity != self.inspect_self()?.identity {
			return Err(invalid("reopened directory identity changed"));
		}
		let mut buffer = Vec::new();
		buffer
			.try_reserve_exact(8192)
			.map_err(|_| Error::OutOfMemory)?;
		buffer.resize(8192, 0);
		Ok(Names {
			file,
			buffer,
			used: 0,
			offset: 0,
			remaining: maximum_entries,
			maximum_name_bytes,
			restart: true,
			finished: false,
		})
	}
}
impl Names {
	fn refill(&mut self) -> Result<bool, Error> {
		let mut io_status = IO_STATUS_BLOCK::default();
		// The owned synchronous handle, initialized writable aligned buffer and
		// status record remain live throughout the call. No callback is installed.
		// Information bounds the bytes inspected, including on later batches.
		let status = unsafe {
			NtQueryDirectoryFile(
				self.file.as_raw_handle(),
				ptr::null_mut(),
				None,
				ptr::null(),
				&mut io_status,
				self.buffer.as_mut_ptr().cast(),
				(self.buffer.len() * size_of::<u64>()) as u32,
				FileNamesInformation,
				false,
				ptr::null(),
				self.restart,
			)
		};
		self.restart = false;
		if status == STATUS_NO_MORE_FILES {
			return Ok(false);
		}
		if status == STATUS_BUFFER_OVERFLOW {
			return Err(Error::LimitExceeded);
		}
		if status != STATUS_SUCCESS {
			return Err(io::Error::from_raw_os_error(
				unsafe { RtlNtStatusToDosError(status) } as i32
			)
			.into());
		}
		self.used = io_status.Information;
		self.offset = 0;
		if self.used < 12 || self.used > self.buffer.len() * size_of::<u64>() {
			return Err(invalid("directory query returned an invalid byte count"));
		}
		Ok(true)
	}
	fn bytes(&self) -> &[u8] {
		// All u64 words are initialized, and every bit pattern remains valid
		// after kernel writes. The exclusive FFI borrow has ended; this view
		// never outlives the buffer or crosses its reported initialized extent.
		unsafe { std::slice::from_raw_parts(self.buffer.as_ptr().cast(), self.used) }
	}
	fn read_next(&mut self) -> Result<Option<Vec<u8>>, Error> {
		loop {
			if self.offset == self.used && !self.refill()? {
				return Ok(None);
			}
			let (next, name) = record(self.bytes(), self.offset)?;
			if name == b".\0" || name == b".\0.\0" {
				self.offset = next;
				continue;
			}
			if self.remaining == 0 {
				return Err(Error::LimitExceeded);
			}
			let name = decode_name(name, self.maximum_name_bytes)?;
			self.offset = next;
			self.remaining -= 1;
			return Ok(Some(name));
		}
	}
}
impl Iterator for Names {
	type Item = Result<Vec<u8>, Error>;
	fn next(&mut self) -> Option<Self::Item> {
		if self.finished {
			return None;
		}
		self.finished = true;
		match self.read_next() {
			Ok(Some(name)) => {
				self.finished = false;
				Some(Ok(name))
			}
			Ok(None) => None,
			Err(error) => Some(Err(error)),
		}
	}
}
impl std::iter::FusedIterator for Names {}

fn invalid(message: &'static str) -> Error {
	io::Error::new(io::ErrorKind::InvalidData, message).into()
}
fn record(bytes: &[u8], offset: usize) -> Result<(usize, &[u8]), Error> {
	let begin = offset
		.checked_add(12)
		.ok_or_else(|| invalid("record offset overflow"))?;
	let header = bytes
		.get(offset..begin)
		.ok_or_else(|| invalid("truncated directory record"))?;
	let next = u32::from_le_bytes([header[0], header[1], header[2], header[3]]) as usize;
	let length = u32::from_le_bytes([header[8], header[9], header[10], header[11]]) as usize;
	let limit = if next == 0 {
		bytes.len()
	} else {
		let limit = offset
			.checked_add(next)
			.ok_or_else(|| invalid("next offset overflow"))?;
		if next < 12 || next % 4 != 0 || limit.checked_add(12).is_none_or(|end| end > bytes.len()) {
			return Err(invalid("invalid next directory record"));
		}
		limit
	};
	let end = begin
		.checked_add(length)
		.ok_or_else(|| invalid("name length overflow"))?;
	if length == 0 || length % 2 != 0 || end > limit {
		return Err(invalid("invalid directory name extent"));
	}
	Ok((limit, &bytes[begin..end]))
}
fn decode_name(bytes: &[u8], maximum: usize) -> Result<Vec<u8>, Error> {
	if bytes.len() % 2 != 0 {
		return Err(Error::InvalidBasename);
	}
	let upper = (bytes.len() / 2)
		.checked_mul(3)
		.ok_or(Error::LimitExceeded)?
		.min(maximum);
	let mut name = Vec::new();
	name.try_reserve_exact(upper)
		.map_err(|_| Error::OutOfMemory)?;
	let units = bytes
		.chunks_exact(2)
		.map(|pair| u16::from_le_bytes([pair[0], pair[1]]));
	for character in char::decode_utf16(units) {
		let character = character.map_err(|_| Error::InvalidBasename)?;
		if character == '\0' {
			return Err(Error::InvalidBasename);
		}
		let mut encoded = [0; 4];
		let encoded = character.encode_utf8(&mut encoded).as_bytes();
		if encoded.len() > maximum - name.len() {
			return Err(Error::LimitExceeded);
		}
		name.extend_from_slice(encoded);
	}
	Ok(name)
}

#[cfg(test)]
#[path = "windows_names_tests.rs"]
mod tests;
