use super::{Content, Entry, Error, MAX_ENTRIES, Snapshot, validate_path, validate_symlink_target};
use crate::metadata::Metadata;
use core::cmp::Ordering;

/// Expanded bytes and all physical metadata relations have been validated.
/// The immutable view cannot invalidate hierarchy or identity afterward.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct CanonicalSnapshot<'a>(Snapshot<'a>);
impl<'a> CanonicalSnapshot<'a> {
	/// Expected O(n log n) path comparisons plus scanned path, extent and shared
	/// file/metadata bytes. Validation and hashing allocate no additional storage.
	pub fn new(snapshot: Snapshot<'a>) -> Result<Self, Error> {
		let Snapshot { entries, root } = &snapshot;
		if entries.len() > MAX_ENTRIES {
			return Err(Error::TooManyEntries);
		}
		for (
			index,
			Entry {
				path,
				content,
				metadata: _,
			},
		) in entries.iter().enumerate()
		{
			validate_path(path)?;
			match content {
				Content::Directory { mode: _ } | Content::File { mode: _, bytes: _ } => {}
				Content::Symlink { target } => validate_symlink_target(path, target)?,
			}
			if index > 0 {
				match entries[index - 1].path.as_ref().cmp(path.as_ref()) {
					Ordering::Equal => return Err(Error::DuplicatePath),
					Ordering::Greater => return Err(Error::PathsNotSorted),
					Ordering::Less => {}
				}
			}
			if let Some(slash) = path.iter().rposition(|byte| *byte == b'/') {
				let parent =
					find_path(&entries[..index], &path[..slash]).ok_or(Error::MissingParent)?;
				if !matches!(entries[parent].content, Content::Directory { mode: _ }) {
					return Err(Error::ParentNotDirectory);
				}
			}
		}
		for (
			index,
			Entry {
				path: _,
				content,
				metadata,
			},
		) in entries.iter().enumerate()
		{
			for hole in &metadata.metadata().holes {
				let Content::File { mode: _, bytes } = content else {
					return Err(Error::InvalidSparseExtent);
				};
				let length = bytes.len() as u64;
				if hole.offset > length || hole.length > length - hole.offset {
					return Err(Error::InvalidSparseExtent);
				}
				let begin = hole.offset as usize;
				let end = begin + hole.length as usize;
				if bytes[begin..end].iter().any(|byte| *byte != 0) {
					return Err(Error::InvalidSparseExtent);
				}
			}
			if let Some(path) = &metadata.metadata().hardlink_to {
				let Content::File { mode, bytes } = content else {
					return Err(Error::InvalidHardlinkRelation);
				};
				let target =
					find_path(&entries[..index], path).ok_or(Error::InvalidHardlinkRelation)?;
				let target = &entries[target];
				let Content::File {
					mode: target_mode,
					bytes: target_bytes,
				} = &target.content
				else {
					return Err(Error::InvalidHardlinkRelation);
				};
				if target.metadata.metadata().hardlink_to.is_some()
					|| mode != target_mode
					|| bytes != target_bytes
					|| !shared_metadata_equal(metadata.metadata(), target.metadata.metadata())
				{
					return Err(Error::InvalidHardlinkRelation);
				}
			}
		}
		if !root.metadata().holes.is_empty() {
			return Err(Error::InvalidSparseExtent);
		}
		if root.metadata().hardlink_to.is_some() {
			return Err(Error::InvalidHardlinkRelation);
		}
		Ok(Self(snapshot))
	}
	pub fn snapshot(&self) -> &Snapshot<'a> {
		&self.0
	}
	pub fn into_snapshot(self) -> Snapshot<'a> {
		self.0
	}
	pub fn hash(&self) -> [u8; 32] {
		let Snapshot { entries, root } = &self.0;
		let mut hash = blake3::Hasher::new();
		hash.update(b"DIFZTREE-ID\x02");
		hash.update(&(entries.len() as u32).to_le_bytes());
		for Entry {
			path,
			content,
			metadata,
		} in entries
		{
			hash.update(&[content.kind_tag()]);
			hash.update(&content.mode().bits().to_le_bytes());
			hash.update(&(path.len() as u32).to_le_bytes());
			hash.update(path);
			hash.update(&(content.bytes().len() as u64).to_le_bytes());
			hash.update(content.bytes());
			hash.update(&metadata.hash());
		}
		if !root.metadata().is_empty() {
			hash.update(b"DIFZTREE-ROOT\x01");
			hash.update(&root.hash());
		}
		*hash.finalize().as_bytes()
	}
}

fn find_path(entries: &[Entry<'_>], path: &[u8]) -> Option<usize> {
	entries
		.binary_search_by(|entry| entry.path.as_ref().cmp(path))
		.ok()
}

// Compare canonical fields directly, excluding only the referring link.
fn shared_metadata_equal(left: &Metadata<'_>, right: &Metadata<'_>) -> bool {
	let Metadata {
		xattrs: lx,
		aces: la,
		native_acl: ln,
		times: lt,
		finder_flags: lf,
		finder_info: li,
		holes: lh,
		hardlink_to: _,
	} = left;
	let Metadata {
		xattrs: rx,
		aces: ra,
		native_acl: rn,
		times: rt,
		finder_flags: rf,
		finder_info: ri,
		holes: rh,
		hardlink_to: _,
	} = right;
	lx == rx && la == ra && ln == rn && lt == rt && lf == rf && li == ri && lh == rh
}
