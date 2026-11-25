//! Owned selection keeps parent closure and rebases hardlinks without copying data.
use super::{CanonicalSnapshot, Content, Entry, Snapshot, structure::find_path};
use crate::{metadata::CanonicalMetadata, path_filter::Filter};
use alloc::{borrow::Cow, vec::Vec};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	Snapshot(super::Error),
	Filter(crate::path_filter::Error),
	Metadata(crate::metadata::Error),
	OutOfMemory,
}
fn reserve<T>(values: &mut Vec<T>, length: usize) -> Result<(), Error> {
	values
		.try_reserve_exact(length)
		.map_err(|_| Error::OutOfMemory)
}
fn path_copy<'a>(path: &Cow<'a, [u8]>) -> Result<Cow<'a, [u8]>, Error> {
	match path {
		Cow::Borrowed(bytes) => Ok(Cow::Borrowed(*bytes)),
		Cow::Owned(bytes) => {
			let mut copy = Vec::new();
			reserve(&mut copy, bytes.len())?;
			copy.extend_from_slice(bytes);
			Ok(Cow::Owned(copy))
		}
	}
}
impl<'a> CanonicalSnapshot<'a> {
	/// Consume a snapshot, retain matching entries and their parents, and move
	/// each retained group's one buffer to its first selected path. No payload
	/// cloning or reference-count allocation is needed when the old name is cut.
	/// Expected work is O(total path bytes * log n) plus filter and validation
	/// work. Index storage is O(n); only rebased path strings need byte copying.
	pub fn selecting(self, filter: &Filter) -> Result<Self, Error> {
		let Snapshot { mut entries, root } = self.into_snapshot();
		let length = entries.len();
		let mut selected = Vec::new();
		reserve(&mut selected, length)?;
		selected.resize(length, false);
		for (index, entry) in entries.iter().enumerate() {
			if !filter.includes(&entry.path).map_err(Error::Filter)? {
				continue;
			}
			selected[index] = true;
			let mut path = entry.path.as_ref();
			while let Some(slash) = path.iter().rposition(|&byte| byte == b'/') {
				path = &path[..slash];
				let parent = find_path(&entries[..index], path)
					.ok_or(Error::Snapshot(super::Error::MissingParent))?;
				selected[parent] = true;
			}
		}
		let mut owners = Vec::new();
		let mut first = Vec::new();
		let mut output_index: Vec<Option<usize>> = Vec::new();
		reserve(&mut owners, length)?;
		reserve(&mut first, length)?;
		reserve(&mut output_index, length)?;
		first.resize(length, None);
		output_index.resize(length, None);
		for (index, entry) in entries.iter().enumerate() {
			let owner = match &entry.content {
				Content::FileAlias { target, mode: _ } => *target,
				Content::File { mode: _, bytes: _ }
				| Content::Directory { mode: _ }
				| Content::Symlink { target: _ } => index,
			};
			owners.push(owner);
			if selected[index] && first[owner].is_none() {
				first[owner] = Some(index);
			}
		}
		// The old canonical name may be excluded. Transfer its buffer before
		// consuming entries, while all old indices still describe the same rows.
		for owner in 0..length {
			let Some(destination) = first[owner] else {
				continue;
			};
			if owner == destination {
				continue;
			}
			let mode = entries[owner].content.mode();
			let content = core::mem::replace(
				&mut entries[owner].content,
				Content::File {
					mode,
					bytes: Cow::Borrowed(b""),
				},
			);
			if !matches!(content, Content::File { .. }) {
				return Err(Error::Snapshot(super::Error::InvalidHardlinkRelation));
			}
			entries[destination].content = content;
		}
		let mut output: Vec<Entry<'a>> = Vec::new();
		reserve(&mut output, selected.iter().filter(|&&keep| keep).count())?;
		for (index, mut entry) in entries.into_iter().enumerate() {
			if !selected[index] {
				continue;
			}
			match &entry.content {
				Content::File { mode: _, bytes: _ } | Content::FileAlias { mode: _, target: _ } => {
					let owner = owners[index];
					let mut metadata = entry.metadata.into_metadata();
					if let Some(target) = output_index[owner] {
						metadata.hardlink_to = Some(path_copy(&output[target].path)?);
						entry.content = Content::FileAlias {
							mode: entry.content.mode(),
							target,
						};
					} else {
						if !matches!(entry.content, Content::File { .. }) {
							return Err(Error::Snapshot(super::Error::InvalidHardlinkRelation));
						}
						metadata.hardlink_to = None;
						output_index[owner] = Some(output.len());
					}
					entry.metadata = CanonicalMetadata::new(metadata).map_err(Error::Metadata)?;
				}
				Content::Directory { mode: _ } | Content::Symlink { target: _ } => {}
			}
			output.push(entry);
		}
		CanonicalSnapshot::new(Snapshot {
			entries: output,
			root,
		})
		.map_err(Error::Snapshot)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{
		directory::Mode,
		metadata::Metadata,
		path_filter::{Action, Rule},
	};
	#[test]
	fn every_three_link_selection_moves_one_owned_buffer_and_rebases_the_first_name() {
		for mask in 0u8..8 {
			let bytes = vec![0, 255, 42];
			let pointer = bytes.as_ptr();
			let mode = Mode::from_bits(0o600).unwrap();
			let mut entries = vec![Entry {
				path: Cow::Borrowed(b"a"),
				content: Content::File {
					mode,
					bytes: Cow::Owned(bytes),
				},
				metadata: CanonicalMetadata::default(),
			}];
			for path in [b"b", b"c"] {
				entries.push(Entry {
					path: Cow::Borrowed(path),
					content: Content::FileAlias { mode, target: 0 },
					metadata: CanonicalMetadata::new(Metadata {
						hardlink_to: Some(Cow::Borrowed(b"a")),
						..Metadata::default()
					})
					.unwrap(),
				});
			}
			let root = CanonicalMetadata::new(Metadata {
				finder_flags: 7,
				..Metadata::default()
			})
			.unwrap();
			let root_hash = root.hash();
			let source = CanonicalSnapshot::new(Snapshot { entries, root }).unwrap();
			let mut rules = vec![Rule {
				action: Action::Exclude,
				pattern: "**",
			}];
			for (index, pattern) in ["a", "b", "c"].into_iter().enumerate() {
				if mask & (1 << index) != 0 {
					rules.push(Rule {
						action: Action::Include,
						pattern,
					});
				}
			}
			let output = source.selecting(&Filter::compile(&rules).unwrap()).unwrap();
			assert_eq!(output.snapshot().entries.len(), mask.count_ones() as usize);
			assert_eq!(output.snapshot().root.hash(), root_hash);
			let expected: Vec<_> = [b"a", b"b", b"c"]
				.into_iter()
				.enumerate()
				.filter(|(index, _)| mask & (1 << index) != 0)
				.map(|(_, name)| name.as_slice())
				.collect();
			for (index, entry) in output.snapshot().entries.iter().enumerate() {
				assert_eq!(entry.path.as_ref(), expected[index]);
				assert_eq!(output.snapshot().entry_bytes(index).unwrap(), [0, 255, 42]);
				assert_eq!(
					output.snapshot().entry_bytes(index).unwrap().as_ptr(),
					pointer
				);
				if index == 0 {
					assert!(matches!(
						entry.content,
						Content::File {
							bytes: Cow::Owned(_),
							..
						}
					));
					assert!(entry.metadata.metadata().hardlink_to.is_none());
				} else {
					assert!(matches!(
						entry.content,
						Content::FileAlias { target: 0, .. }
					));
					assert_eq!(
						entry.metadata.metadata().hardlink_to.as_deref(),
						Some(expected[0])
					);
				}
			}
		}
	}
	#[test]
	fn selecting_a_nested_alias_retains_parents_and_moves_the_excluded_canonical_payload() {
		let mut raw = crate::directory::canonical_tests::fixture(1);
		let bytes = vec![0, 0, b'X', 0];
		let pointer = bytes.as_ptr();
		raw.entries[1].content = Content::File {
			mode: Mode::from_bits(0o644).unwrap(),
			bytes: Cow::Owned(bytes),
		};
		let source = CanonicalSnapshot::new(raw).unwrap();
		let output = source
			.selecting(
				&Filter::compile(&[Rule {
					action: Action::Include,
					pattern: "a/z",
				}])
				.unwrap(),
			)
			.unwrap();
		assert_eq!(
			output
				.snapshot()
				.entries
				.iter()
				.map(|entry| entry.path.as_ref())
				.collect::<Vec<_>>(),
			[b"a".as_slice(), b"a/z"]
		);
		assert!(matches!(
			output.snapshot().entries[0].content,
			Content::Directory { .. }
		));
		assert_eq!(output.snapshot().entry_bytes(1).unwrap().as_ptr(), pointer);
		assert!(
			output.snapshot().entries[1]
				.metadata
				.metadata()
				.hardlink_to
				.is_none()
		);
		assert_eq!(
			output.snapshot().entries[1].metadata.metadata().holes.len(),
			1
		);
	}
}
