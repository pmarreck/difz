use super::{Error, HEADER_LEN, Header, Limits, Operation};
use crate::{
	directory::{CanonicalSnapshot, Content, Entry, Snapshot, structure::find_path},
	metadata::{CanonicalMetadata, Omit},
	path_filter::{Action, Filter, Rule},
};
use alloc::{borrow::Cow, vec::Vec};

#[derive(Clone, Copy, Debug, Default)]
pub struct CreateOptions<'a> {
	pub rules: &'a [Rule<'a>],
	pub omit: Omit,
}

/// Encode one complete v2 snapshot, selecting same-path copies or source-prefix
/// deltas. Expected work is linear in bytes plus O(n log n) path comparisons
/// and codec work. File buffers are borrowed while projecting metadata.
pub fn create(
	source: &CanonicalSnapshot<'_>,
	target: &CanonicalSnapshot<'_>,
	options: CreateOptions<'_>,
) -> Result<Vec<u8>, Error> {
	let CreateOptions { rules, omit } = options;
	let limits = Limits::default();
	let source_projection;
	let target_projection;
	let (source, target) = if omit.bits() == 0 {
		(source, target)
	} else {
		source_projection = project(source, omit)?;
		target_projection = project(target, omit)?;
		(&source_projection, &target_projection)
	};
	if rules.len() as u64 > u64::from(limits.envelope.max_rules) {
		return Err(Error::LimitExceeded);
	}
	// Preserve native precedence: compile all rules before checking wire lengths.
	drop(Filter::compile(rules).map_err(Error::Filter)?);
	let header = Header {
		needed_reader: 2,
		root_metadata: !target.snapshot().root.metadata().is_empty(),
		omit,
		rule_count: rules.len() as u32,
		entry_count: target.snapshot().entries.len() as u32,
		source_hash: source.hash(),
		target_hash: target.hash(),
	};
	let mut output = Writer {
		bytes: Vec::new(),
		maximum: limits.envelope.max_patch_bytes,
	};
	output.put(&[0; HEADER_LEN])?;
	for &Rule { action, pattern } in rules {
		if pattern.is_empty() || pattern.len() as u64 > u64::from(limits.max_pattern_bytes) {
			return Err(Error::LimitExceeded);
		}
		output.put(&[
			match action {
				Action::Include => 1,
				Action::Exclude => 2,
			},
			0,
			0,
			0,
		])?;
		output.put(&(pattern.len() as u32).to_le_bytes())?;
		output.put(pattern.as_bytes())?;
	}
	for Entry {
		path,
		content,
		metadata,
	} in &target.snapshot().entries
	{
		let (operation, payload) = match content {
			Content::Directory { mode: _ } => (Operation::Directory, Cow::Borrowed(b"".as_slice())),
			Content::Symlink { target } => {
				if target.len() as u64 > limits.max_symlink_bytes {
					return Err(Error::LimitExceeded);
				}
				(Operation::Symlink, Cow::Borrowed(target.as_ref()))
			}
			Content::File { mode: _, bytes } => {
				if let Some(link) = &metadata.metadata().hardlink_to {
					(Operation::FileHardlink, Cow::Borrowed(link.as_ref()))
				} else {
					let old = find_path(&source.snapshot().entries, path)
						.map(|i| &source.snapshot().entries[i].content);
					match old {
						Some(Content::File {
							mode: _,
							bytes: previous,
						}) if previous == bytes => (Operation::FileCopy, Cow::Borrowed(b"".as_slice())),
						Some(Content::File {
							mode: _,
							bytes: previous,
						}) => (
							Operation::FileDelta,
							Cow::Owned(crate::file::encode(previous, bytes).map_err(Error::File)?),
						),
						Some(Content::Directory { mode: _ } | Content::Symlink { target: _ })
						| None => (Operation::FileRaw, Cow::Borrowed(bytes.as_ref())),
					}
				}
			}
		};
		if payload.len() as u64 > limits.max_payload_bytes {
			return Err(Error::LimitExceeded);
		}
		output.put(&[operation as u8, 0])?;
		output.put(&content.mode().bits().to_le_bytes())?;
		output.put(&(path.len() as u32).to_le_bytes())?;
		output.put(&(payload.len() as u64).to_le_bytes())?;
		output.put(path)?;
		output.put(&payload)?;
		output.metadata(metadata, limits.max_payload_bytes)?;
	}
	if header.root_metadata {
		output.metadata(&target.snapshot().root, limits.max_payload_bytes)?;
	}
	let encoded = header.encode(&output.bytes[HEADER_LEN..]);
	output.bytes[..HEADER_LEN].copy_from_slice(&encoded);
	Ok(output.bytes)
}

pub(super) fn project<'a>(
	source: &'a CanonicalSnapshot<'_>,
	omit: Omit,
) -> Result<CanonicalSnapshot<'a>, Error> {
	let Snapshot { entries, root } = source.snapshot();
	let mut projected = Vec::new();
	projected
		.try_reserve_exact(entries.len())
		.map_err(|_| Error::OutOfMemory)?;
	for Entry {
		path,
		content,
		metadata,
	} in entries
	{
		let content = match content {
			Content::Directory { mode } => Content::Directory { mode: *mode },
			Content::File { mode, bytes } => Content::File {
				mode: *mode,
				bytes: Cow::Borrowed(bytes),
			},
			Content::Symlink { target } => Content::Symlink {
				target: Cow::Borrowed(target),
			},
		};
		projected.push(Entry {
			path: Cow::Borrowed(path),
			content,
			metadata: metadata.borrowing_omitting(omit).map_err(Error::Metadata)?,
		});
	}
	CanonicalSnapshot::new(Snapshot {
		entries: projected,
		root: root.borrowing_omitting(omit).map_err(Error::Metadata)?,
	})
	.map_err(Error::Snapshot)
}

struct Writer {
	bytes: Vec<u8>,
	maximum: u64,
}
impl Writer {
	fn put(&mut self, bytes: &[u8]) -> Result<(), Error> {
		let length = self
			.bytes
			.len()
			.checked_add(bytes.len())
			.ok_or(Error::LimitExceeded)?;
		if length as u64 > self.maximum {
			return Err(Error::LimitExceeded);
		}
		self.bytes
			.try_reserve(bytes.len())
			.map_err(|_| Error::OutOfMemory)?;
		self.bytes.extend_from_slice(bytes);
		Ok(())
	}
	fn metadata(&mut self, metadata: &CanonicalMetadata<'_>, maximum: u64) -> Result<(), Error> {
		let bytes = metadata.encode().map_err(Error::Metadata)?;
		if bytes.len() as u64 > maximum {
			return Err(Error::LimitExceeded);
		}
		let length = u32::try_from(bytes.len()).map_err(|_| Error::LimitExceeded)?;
		self.put(&length.to_le_bytes())?;
		self.put(&bytes)
	}
}

#[cfg(test)]
#[path = "tree_patch_encode_tests.rs"]
pub(super) mod tests;
