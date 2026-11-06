use super::{DecodedEntry, Error, Limits, Operation, ParsedPatch, encode::project};
use crate::directory::{CanonicalSnapshot, Content, Entry, Mode, Snapshot, structure::find_path};
use alloc::{borrow::Cow, vec::Vec};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ApplyLimits {
	pub patch: Limits,
	pub max_output_bytes: u64,
}
impl Default for ApplyLimits {
	fn default() -> Self {
		Self {
			patch: Limits::default(),
			max_output_bytes: 64 << 30,
		}
	}
}
/// Verify the source before expanding any files, bound total logical output,
/// then validate physical relations and the complete target identity. Byte
/// buffers borrow source/patch where possible; delta output is Rust-owned.
/// Expected work is linear in bytes plus O(n log n) lookups and codec work.
pub fn apply<'a>(
	source: &'a CanonicalSnapshot<'_>,
	patch: &'a [u8],
	limits: ApplyLimits,
) -> Result<CanonicalSnapshot<'a>, Error> {
	let ApplyLimits {
		patch: patch_limits,
		max_output_bytes,
	} = limits;
	let ParsedPatch {
		header,
		rules: _,
		entries: encoded,
		root,
	} = ParsedPatch::decode(patch, patch_limits)?;
	let projected;
	let masked = if header.omit.bits() == 0 {
		source
	} else {
		projected = project(source, header.omit)?;
		&projected
	};
	if masked.hash() != header.source_hash {
		return Err(Error::SourceHashMismatch);
	}
	let mut entries: Vec<Entry<'a>> = Vec::new();
	entries
		.try_reserve_exact(encoded.len())
		.map_err(|_| Error::OutOfMemory)?;
	let mut remaining = max_output_bytes;
	for DecodedEntry {
		path,
		mode,
		operation,
		payload,
		metadata,
	} in encoded
	{
		let mode = Mode::from_bits(mode).map_err(Error::Snapshot)?;
		let content = match operation {
			Operation::Directory => Content::Directory { mode },
			Operation::Symlink => {
				account(&mut remaining, payload.len())?;
				Content::Symlink {
					target: Cow::Borrowed(payload),
				}
			}
			Operation::FileRaw => {
				account(&mut remaining, payload.len())?;
				Content::File {
					mode,
					bytes: Cow::Borrowed(payload),
				}
			}
			Operation::FileCopy | Operation::FileDelta => {
				let index =
					find_path(&source.snapshot().entries, path).ok_or(Error::MissingSourceEntry)?;
				let Content::File { mode: _, bytes } = &source.snapshot().entries[index].content
				else {
					return Err(Error::SourceKindMismatch);
				};
				let bytes = if operation == Operation::FileCopy {
					account(&mut remaining, bytes.len())?;
					Cow::Borrowed(bytes.as_ref())
				} else {
					let bytes = delta(bytes, payload, remaining)?;
					account(&mut remaining, bytes.len())?;
					Cow::Owned(bytes)
				};
				Content::File { mode, bytes }
			}
			Operation::FileHardlink => {
				let index = find_path(&entries, payload).ok_or(Error::Snapshot(
					crate::directory::Error::InvalidHardlinkRelation,
				))?;
				let target = &entries[index];
				if target.metadata.metadata().hardlink_to.is_some() {
					return Err(Error::Snapshot(
						crate::directory::Error::InvalidHardlinkRelation,
					));
				}
				let Content::File { mode: _, bytes } = &target.content else {
					return Err(Error::Snapshot(
						crate::directory::Error::InvalidHardlinkRelation,
					));
				};
				account(&mut remaining, bytes.len())?;
				let bytes = match bytes {
					Cow::Borrowed(bytes) => Cow::Borrowed(*bytes),
					Cow::Owned(bytes) => {
						// A returned snapshot cannot borrow another entry's owned Vec.
						// Keep ownership explicit and fallible until shared buffers are qualified.
						let mut copy = Vec::new();
						copy.try_reserve_exact(bytes.len())
							.map_err(|_| Error::OutOfMemory)?;
						copy.extend_from_slice(bytes);
						Cow::Owned(copy)
					}
				};
				Content::File { mode, bytes }
			}
		};
		entries.push(Entry {
			path: Cow::Borrowed(path),
			content,
			metadata,
		});
	}
	let result = CanonicalSnapshot::new(Snapshot { entries, root }).map_err(Error::Snapshot)?;
	if result.hash() != header.target_hash {
		return Err(Error::TargetHashMismatch);
	}
	Ok(result)
}

fn account(remaining: &mut u64, bytes: usize) -> Result<(), Error> {
	*remaining = remaining
		.checked_sub(bytes as u64)
		.ok_or(Error::LimitExceeded)?;
	Ok(())
}
fn delta(source: &[u8], patch: &[u8], remaining: u64) -> Result<Vec<u8>, Error> {
	let (header, _) =
		crate::Header::decode_prefix(patch).map_err(|error| Error::File(error.into()))?;
	if header.target_len > remaining {
		// Retain native source/window error precedence while enforcing the tree
		// output budget before decompression, rather than after allocation.
		if header.source_len != source.len() as u64 {
			return Err(Error::File(crate::file::Error::SizeMismatch));
		}
		if header.source_hash != *blake3::hash(source).as_bytes() {
			return Err(Error::File(crate::file::Error::SourceHashMismatch));
		}
		crate::file::window_log(source.len() as u64, header.target_len).map_err(Error::File)?;
		return Err(Error::LimitExceeded);
	}
	crate::file::apply(source, patch, 0).map_err(Error::File)
}
#[cfg(test)]
#[path = "tree_patch_apply_tests.rs"]
mod tests;
