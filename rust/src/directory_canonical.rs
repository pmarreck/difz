use super::{Content, Entry, Error, Snapshot, structure};
use crate::metadata::Metadata;
use structure::find_path;

/// Expanded bytes and all physical metadata relations have been validated.
/// The immutable view cannot invalidate hierarchy or identity afterward.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct CanonicalSnapshot<'a>(Snapshot<'a>);
impl<'a> CanonicalSnapshot<'a> {
	/// Expected O(n log n) path comparisons plus scanned path, extent and shared
	/// file/metadata bytes. Validation and hashing allocate no additional storage.
	pub fn new(mut snapshot: Snapshot<'a>) -> Result<Self, Error> {
		let Snapshot { entries, root } = &snapshot;
		structure::validate(entries)?;
		for (
			index,
			Entry {
				path: _,
				content,
				metadata,
			},
		) in entries.iter().enumerate()
		{
			if let Content::FileAlias { target, mode: _ } = content {
				if metadata
					.metadata()
					.hardlink_to
					.as_ref()
					.and_then(|path| find_path(&entries[..index], path))
					!= Some(*target)
				{
					return Err(Error::InvalidHardlinkRelation);
				}
			}
			for hole in &metadata.metadata().holes {
				let bytes = match content {
					Content::File { mode: _, bytes } => bytes.as_ref(),
					Content::FileAlias { mode: _, target: _ } => snapshot
						.entry_bytes(index)
						.ok_or(Error::InvalidHardlinkRelation)?,
					Content::Directory { mode: _ } | Content::Symlink { target: _ } => {
						return Err(Error::InvalidSparseExtent);
					}
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
				let (mode, bytes) = match content {
					Content::File { mode, bytes } => (mode, bytes.as_ref()),
					Content::FileAlias { mode, target: _ } => (
						mode,
						snapshot
							.entry_bytes(index)
							.ok_or(Error::InvalidHardlinkRelation)?,
					),
					Content::Directory { mode: _ } | Content::Symlink { target: _ } => {
						return Err(Error::InvalidHardlinkRelation);
					}
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
					|| bytes != target_bytes.as_ref()
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
		// Normalize every validated hardlink to one earlier canonical buffer.
		// Drop duplicate owned payloads instead of requiring reference counts or
		// borrowing another entry's movable Vec. All indices are already proven.
		for index in 0..snapshot.entries.len() {
			let entry = &snapshot.entries[index];
			if let Some(path) = &entry.metadata.metadata().hardlink_to {
				let target = find_path(&snapshot.entries[..index], path)
					.ok_or(Error::InvalidHardlinkRelation)?;
				let mode = entry.content.mode();
				snapshot.entries[index].content = Content::FileAlias { mode, target };
			}
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
		for (
			index,
			Entry {
				path,
				content,
				metadata,
			},
		) in entries.iter().enumerate()
		{
			hash.update(&[content.kind_tag()]);
			hash.update(&content.mode().bits().to_le_bytes());
			hash.update(&(path.len() as u32).to_le_bytes());
			hash.update(path);
			let bytes = self.0.entry_bytes(index).expect("validated entry bytes");
			hash.update(&(bytes.len() as u64).to_le_bytes());
			hash.update(bytes);
			hash.update(&metadata.hash());
		}
		if !root.metadata().is_empty() {
			hash.update(b"DIFZTREE-ROOT\x01");
			hash.update(&root.hash());
		}
		*hash.finalize().as_bytes()
	}
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
