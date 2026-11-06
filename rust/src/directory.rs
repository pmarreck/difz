//! Portable tree path grammar. Filesystem effects are separate adapters.

pub const MAX_ENTRIES: usize = 1_000_000;
pub const MAX_PATH_BYTES: usize = 4096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	EmptyPath,
	InvalidUtf8,
	AbsolutePath,
	BackslashSeparator,
	NulByte,
	InvalidComponent,
	DrivePrefix,
	PathsNotSorted,
	DuplicatePath,
	MissingParent,
	ParentNotDirectory,
	InvalidMode,
	InvalidEntryData,
	SymlinkEscapesRoot,
	TooManyEntries,
	PathTooLong,
	InvalidHardlinkRelation,
	InvalidSparseExtent,
}

// Shared text checks retain the native precedence for conflicting errors.
fn validate_text(bytes: &[u8]) -> Result<(), Error> {
	if core::str::from_utf8(bytes).is_err() {
		return Err(Error::InvalidUtf8);
	}
	if bytes.starts_with(b"/") {
		return Err(Error::AbsolutePath);
	}
	if bytes.contains(&b'\\') {
		return Err(Error::BackslashSeparator);
	}
	if bytes.contains(&0) {
		return Err(Error::NulByte);
	}
	if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
		return Err(Error::DrivePrefix);
	}
	Ok(())
}

/// Linear in path bytes, with no allocation. Limits count bytes, not characters.
pub fn validate_path(path: &[u8]) -> Result<(), Error> {
	if path.is_empty() {
		return Err(Error::EmptyPath);
	}
	if path.len() > MAX_PATH_BYTES {
		return Err(Error::PathTooLong);
	}
	validate_text(path)?;
	if path
		.split(|byte| *byte == b'/')
		.any(|part| part.is_empty() || part == b"." || part == b"..")
	{
		return Err(Error::InvalidComponent);
	}
	Ok(())
}

/// Linear in link/target bytes, with no allocation or filesystem traversal.
pub fn validate_symlink_target(link_path: &[u8], target: &[u8]) -> Result<(), Error> {
	validate_path(link_path)?;
	if target.is_empty() {
		return Err(Error::InvalidEntryData);
	}
	validate_text(target)?;
	let mut depth = link_path.iter().filter(|byte| **byte == b'/').count();
	for part in target.split(|byte| *byte == b'/') {
		match part {
			b"" => return Err(Error::InvalidComponent),
			b"." => {}
			b".." => {
				if depth == 0 {
					return Err(Error::SymlinkEscapesRoot);
				}
				depth -= 1;
			}
			_ => depth += 1,
		}
	}
	Ok(())
}

#[cfg(test)]
#[path = "directory_tests.rs"]
mod tests;
