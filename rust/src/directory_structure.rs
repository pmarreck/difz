use super::{Content, Entry, Error, MAX_ENTRIES, Mode, validate_path, validate_symlink_target};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Kind {
	Directory,
	File,
	Symlink,
}
pub(crate) struct Record<'a> {
	pub path: &'a [u8],
	pub mode: u16,
	pub kind: Kind,
	pub data: &'a [u8],
}
pub(crate) trait View {
	fn structure(&self) -> Record<'_>;
}
impl View for Entry<'_> {
	fn structure(&self) -> Record<'_> {
		let Entry {
			path,
			content,
			metadata: _,
		} = self;
		let (kind, mode, data) = match content {
			Content::Directory { mode } => (Kind::Directory, mode.bits(), b"".as_slice()),
			Content::File { mode, bytes } => (Kind::File, mode.bits(), bytes.as_ref()),
			Content::Symlink { target } => (Kind::Symlink, 0o777, target.as_ref()),
		};
		Record {
			path,
			mode,
			kind,
			data,
		}
	}
}
pub(crate) fn find_path<T: View>(entries: &[T], path: &[u8]) -> Option<usize> {
	entries
		.binary_search_by(|entry| entry.structure().path.cmp(path))
		.ok()
}
/// Validate only ordered hierarchy and entry shape. File bytes may still be
/// encoded payloads; sparse/hardlink relations and root metadata are separate.
/// Expected work is O(n log n) path comparisons plus scanned path/link bytes.
pub(crate) fn validate<T: View>(entries: &[T]) -> Result<(), Error> {
	if entries.len() > MAX_ENTRIES {
		return Err(Error::TooManyEntries);
	}
	for (index, entry) in entries.iter().enumerate() {
		let Record {
			path,
			mode,
			kind,
			data,
		} = entry.structure();
		validate_path(path)?;
		Mode::from_bits(mode)?;
		match kind {
			Kind::Directory => {
				if !data.is_empty() {
					return Err(Error::InvalidEntryData);
				}
			}
			Kind::File => {}
			Kind::Symlink => {
				if mode != 0o777 {
					return Err(Error::InvalidMode);
				}
				validate_symlink_target(path, data)?;
			}
		}
		if index > 0 {
			match entries[index - 1].structure().path.cmp(path) {
				core::cmp::Ordering::Equal => return Err(Error::DuplicatePath),
				core::cmp::Ordering::Greater => return Err(Error::PathsNotSorted),
				core::cmp::Ordering::Less => {}
			}
		}
		if let Some(slash) = path.iter().rposition(|byte| *byte == b'/') {
			let parent =
				find_path(&entries[..index], &path[..slash]).ok_or(Error::MissingParent)?;
			match entries[parent].structure().kind {
				Kind::Directory => {}
				Kind::File | Kind::Symlink => return Err(Error::ParentNotDirectory),
			}
		}
	}
	Ok(())
}

#[cfg(test)]
#[path = "directory_structure_tests.rs"]
mod tests;
