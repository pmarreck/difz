use crate::{catalog::Catalog, ffi};
use std::{
	ffi::OsStr,
	fs::{self, File, OpenOptions},
	io::{Read, Write},
	path::Path,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Kind {
	Stream,
	File,
	Directory,
	Special,
}
pub fn stream_input(path: &OsStr) -> bool {
	path == "-" || path == "@stdin"
}
pub fn stream_output(path: Option<&OsStr>) -> bool {
	path.is_none_or(|path| path == "-" || path == "@stdout" || path == "@stderr")
}
pub fn classify(path: &OsStr, messages: &Catalog) -> Result<Kind, String> {
	if stream_input(path) {
		return Ok(Kind::Stream);
	}
	let metadata = fs::symlink_metadata(path).map_err(|error| {
		format!(
			"{} '{}': {error}",
			messages.cannot_open,
			path.to_string_lossy()
		)
	})?;
	Ok(if metadata.is_file() {
		Kind::File
	} else if metadata.is_dir() {
		Kind::Directory
	} else {
		Kind::Special
	})
}
fn read_bounded(
	reader: &mut impl Read,
	maximum: u64,
	messages: &Catalog,
) -> Result<Vec<u8>, String> {
	let mut output = Vec::new();
	let mut buffer = [0u8; 65_536];
	loop {
		let count = match reader.read(&mut buffer) {
			Ok(count) => count,
			Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
			Err(error) => return Err(format!("{}: {error}", messages.read_error)),
		};
		if count == 0 {
			return Ok(output);
		}
		if output.len() as u64 + count as u64 > maximum {
			return Err(messages.resource_limit.into());
		}
		output
			.try_reserve(count)
			.map_err(|_| messages.out_of_memory.to_owned())?;
		output.extend_from_slice(&buffer[..count]);
	}
}
pub fn load(path: &OsStr, maximum: u64, messages: &Catalog) -> Result<Vec<u8>, String> {
	if stream_input(path) {
		return read_bounded(&mut std::io::stdin().lock(), maximum, messages);
	}
	let mut options = OpenOptions::new();
	options.read(true);
	#[cfg(unix)]
	{
		use std::os::unix::fs::OpenOptionsExt;
		options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
	}
	let mut file = options.open(path).map_err(|error| {
		format!(
			"{} '{}': {error}",
			messages.cannot_open,
			path.to_string_lossy()
		)
	})?;
	let metadata = file
		.metadata()
		.map_err(|error| format!("{}: {error}", messages.read_error))?;
	if !metadata.is_file() {
		return Err(messages.special_input.into());
	}
	if metadata.len() > maximum {
		return Err(messages.resource_limit.into());
	}
	read_bounded(&mut file, maximum, messages)
}
pub fn output(
	path: Option<&OsStr>,
	bytes: &[u8],
	atomic: bool,
	messages: &Catalog,
) -> Result<(), String> {
	let result = match path {
		None => write_and_flush(&mut std::io::stdout().lock(), bytes),
		Some(path) if path == "-" || path == "@stdout" => {
			write_and_flush(&mut std::io::stdout().lock(), bytes)
		}
		Some(path) if path == "@stderr" => write_and_flush(&mut std::io::stderr().lock(), bytes),
		Some(path) if atomic => return new_file(path, bytes, messages),
		Some(path) => File::create(path).and_then(|mut file| write_and_flush(&mut file, bytes)),
	};
	result.map_err(|error| format!("{}: {error}", messages.write_error))
}
fn write_and_flush(writer: &mut impl Write, bytes: &[u8]) -> std::io::Result<()> {
	writer.write_all(bytes)?;
	writer.flush()
}
pub fn split_output<'a>(
	path: &'a OsStr,
	messages: &Catalog,
) -> Result<(&'a OsStr, &'a OsStr), String> {
	let path = Path::new(path);
	let name = path
		.file_name()
		.ok_or_else(|| messages.write_error.to_owned())?;
	let parent = path
		.parent()
		.filter(|value| !value.as_os_str().is_empty())
		.unwrap_or_else(|| Path::new("."));
	Ok((parent.as_os_str(), name))
}
fn new_file(path: &OsStr, bytes: &[u8], messages: &Catalog) -> Result<(), String> {
	let (parent, name) = split_output(path, messages)?;
	let parent = parent.as_encoded_bytes();
	let name = name.as_encoded_bytes();
	// Explicit borrowed OS path/data lengths remain live through the C call.
	let status = unsafe {
		ffi::difz_new_file_publish(
			parent.as_ptr(),
			parent.len(),
			name.as_ptr(),
			name.len(),
			bytes.as_ptr(),
			bytes.len(),
		)
	};
	crate::check(status, messages.write_error, messages)
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::catalog::EN;
	#[test]
	fn streams_and_bounded_reads_have_exact_zero_and_boundary_behavior() {
		assert_eq!(
			read_bounded(&mut &b"binary\0\xff"[..], 8, &EN).unwrap(),
			b"binary\0\xff"
		);
		assert!(read_bounded(&mut &b"binary\0\xff"[..], 7, &EN).is_err());
		assert!(read_bounded(&mut &b"x"[..], 0, &EN).is_err());
		assert!(read_bounded(&mut &b""[..], 0, &EN).unwrap().is_empty());
		assert!(stream_output(Some("@stderr".as_ref())));
		assert!(!stream_input("@stderr".as_ref()));
	}
}
