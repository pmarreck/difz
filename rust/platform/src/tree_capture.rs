//! Bounded tree capture through pinned, no-follow filesystem capabilities.
use crate::{Directory, EntryInfo, Error, Identity, Kind, Names, owned, read_limited};
#[cfg(target_os = "linux")]
use crate::{linux_snapshot_metadata as metadata, linux_symlink_capture::ParentTransport};
#[cfg(windows)]
use crate::{windows_snapshot_metadata as metadata, windows_snapshot_metadata::ParentTransport};
use difz_core::{
	directory::{self, CanonicalSnapshot, Content, Entry, Snapshot},
	metadata::{CanonicalMetadata, Omit},
	path_filter::{Filter, Rule},
};
#[cfg(target_os = "linux")]
use std::os::unix::fs::MetadataExt;
use std::{
	borrow::Cow,
	collections::{HashMap, HashSet},
	fs::File,
	io,
};

#[derive(Clone, Copy, Debug)]
pub struct Limits {
	pub entries: usize,
	/// Logical payload, path and encoded metadata bytes before and after selection.
	pub bytes: u64,
	pub metadata: metadata::Limits,
}
impl Default for Limits {
	fn default() -> Self {
		Self {
			entries: directory::MAX_ENTRIES,
			bytes: 64 << 30,
			metadata: metadata::Limits::default(),
		}
	}
}
#[derive(Clone, Copy, Default)]
pub struct Options<'a> {
	pub omit: Omit,
	pub rules: &'a [Rule<'a>],
	pub limits: Limits,
}
pub struct Captured {
	snapshot: CanonicalSnapshot<'static>,
	directories: HashSet<Identity>,
}
impl Captured {
	pub fn snapshot(&self) -> &CanonicalSnapshot<'static> {
		&self.snapshot
	}
	pub fn into_snapshot(self) -> CanonicalSnapshot<'static> {
		self.snapshot
	}
	/// A later staged writer must reject an output parent inside its source.
	/// Include every traversed directory, including those excluded by filtering.
	pub fn contains_directory(&self, directory: &Directory) -> Result<bool, Error> {
		Ok(self
			.directories
			.contains(&directory.inspect_self()?.identity))
	}
}
enum Handle<'a> {
	Root(&'a Directory),
	Child(Directory),
}
impl Handle<'_> {
	fn directory(&self) -> &Directory {
		match self {
			Self::Root(value) => value,
			Self::Child(value) => value,
		}
	}
}
struct Frame<'a> {
	handle: Handle<'a>,
	prefix: Vec<u8>,
	names: Names,
	before: EntryInfo,
	transport: ParentTransport,
}
fn frame<'a>(
	handle: Handle<'a>,
	prefix: Vec<u8>,
	before: EntryInfo,
	options: Options<'_>,
) -> Result<Frame<'a>, Error> {
	let directory = handle.directory();
	if directory.inspect_self()? != before {
		return Err(changed());
	}
	let transport = ParentTransport::read(directory, options.omit, options.limits.metadata)?;
	let names = directory.names(
		options.limits.entries.min(directory::MAX_ENTRIES),
		directory::MAX_PATH_BYTES,
	)?;
	if directory.inspect_self()? != before {
		return Err(changed());
	}
	Ok(Frame {
		handle,
		prefix,
		names,
		before,
		transport,
	})
}
struct Row {
	entry: Entry<'static>,
	physical: Option<Identity>,
}

/// Capture all input before selection, matching native error/filter behavior.
/// Per-object and traversal limits bound retained data; allocation is fallible.
/// Iterative frames avoid recursion. Identity/time checks reject observed
/// changes, but do not promise an atomic snapshot of concurrent writers.
pub fn capture(root: &Directory, options: Options<'_>) -> Result<Captured, Error> {
	let filter = Filter::compile(options.rules).map_err(Error::Filter)?;
	let (root_info, root_metadata) =
		metadata::capture(root.clone_file()?, options.omit, options.limits.metadata)?;
	let mut remaining = options
		.limits
		.bytes
		.checked_sub(root_metadata.encoded_len().map_err(Error::Metadata)? as u64)
		.ok_or(Error::LimitExceeded)?;
	let mut rows = Vec::new();
	let mut directories = HashSet::new();
	directories.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
	directories.insert(root_info.identity);
	let mut stack = Vec::new();
	stack.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
	stack.push(frame(Handle::Root(root), Vec::new(), root_info, options)?);
	while let Some(current) = stack.last_mut() {
		let Some(name) = current.names.next() else {
			if current.handle.directory().inspect_self()? != current.before {
				return Err(changed());
			}
			stack.pop();
			continue;
		};
		let name = name?;
		if rows.len() >= options.limits.entries.min(directory::MAX_ENTRIES) {
			return Err(Error::LimitExceeded);
		}
		let path = join(&current.prefix, &name)?;
		let parent = current.handle.directory();
		let named = parent.inspect(&name)?;
		let mut next = None;
		let (content, attributes, physical) = match named.kind {
			Kind::Directory => {
				let child = parent.open_directory(&name)?;
				let (info, attributes) =
					metadata::capture(child.clone_file()?, options.omit, options.limits.metadata)?;
				if info != named {
					return Err(changed());
				}
				// Copy only the bounded traversal prefix; payload ownership moves.
				next = Some(frame(Handle::Child(child), owned(&path)?, info, options)?);
				(Content::Directory { mode: info.mode }, attributes, None)
			}
			Kind::File => {
				if named.length > remaining {
					return Err(Error::LimitExceeded);
				}
				let mut file = parent.open_regular_file(&name)?;
				if EntryInfo::for_file(&file)? != named {
					return Err(changed());
				}
				let linked = hardlinked(&file, options.omit)?;
				let maximum = usize::try_from(remaining).unwrap_or(usize::MAX);
				let bytes = read_limited(&mut file, maximum)?;
				let (info, attributes) =
					metadata::capture(file, options.omit, options.limits.metadata)?;
				if info != named || info.length != bytes.len() as u64 {
					return Err(changed());
				}
				(
					Content::File {
						mode: info.mode,
						bytes: Cow::Owned(bytes),
					},
					attributes,
					linked.then_some(info.identity),
				)
			}
			Kind::Symlink => {
				let mut target = parent.read_symlink(&name, directory::MAX_PATH_BYTES)?;
				if cfg!(windows) {
					for byte in &mut target {
						if *byte == b'\\' {
							*byte = b'/';
						}
					}
				}
				let (info, attributes) = current.transport.capture(parent, &name)?;
				if info != named || parent.inspect(&name)? != named {
					return Err(changed());
				}
				(
					Content::Symlink {
						target: Cow::Owned(target),
					},
					attributes,
					None,
				)
			}
			Kind::Other => return Err(Error::WrongKind),
		};
		let metadata_bytes = attributes.encoded_len().map_err(Error::Metadata)? as u64;
		let cost = (path.len() as u64)
			.checked_add(content.bytes().ok_or_else(changed)?.len() as u64)
			.and_then(|value| value.checked_add(metadata_bytes))
			.ok_or(Error::LimitExceeded)?;
		remaining = remaining.checked_sub(cost).ok_or(Error::LimitExceeded)?;
		rows.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
		rows.push(Row {
			entry: Entry {
				path: Cow::Owned(path),
				content,
				metadata: attributes,
			},
			physical,
		});
		if let Some(next) = next {
			if stack
				.iter()
				.any(|ancestor| ancestor.before.identity == next.before.identity)
			{
				return Err(changed());
			}
			directories.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
			directories.insert(next.before.identity);
			stack.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
			stack.push(next);
		}
	}
	rows.sort_unstable_by(|left, right| left.entry.path.cmp(&right.entry.path));
	let mut entries = Vec::new();
	let mut identities = Vec::new();
	entries
		.try_reserve_exact(rows.len())
		.map_err(|_| Error::OutOfMemory)?;
	identities
		.try_reserve_exact(rows.len())
		.map_err(|_| Error::OutOfMemory)?;
	// The parallel index is created once in this exhaustive consuming loop;
	// snapshot validation preserves entry order and count.
	for Row { entry, physical } in rows {
		entries.push(entry);
		identities.push(physical);
	}
	let mut snapshot = CanonicalSnapshot::new(Snapshot {
		entries,
		root: root_metadata,
	})
	.map_err(Error::Snapshot)?
	.into_snapshot();
	if !options.omit.contains(difz_core::metadata::Family::Hardlink) {
		assign_physical(&mut snapshot, &identities)?;
	}
	let snapshot = CanonicalSnapshot::new(snapshot).map_err(Error::Snapshot)?;
	check_size(&snapshot, options.limits.bytes)?;
	let snapshot = snapshot.selecting(&filter).map_err(Error::Selection)?;
	check_size(&snapshot, options.limits.bytes)?;
	Ok(Captured {
		snapshot,
		directories,
	})
}
fn check_size(snapshot: &CanonicalSnapshot<'_>, maximum: u64) -> Result<(), Error> {
	let mut remaining = maximum
		.checked_sub(
			snapshot
				.snapshot()
				.root
				.encoded_len()
				.map_err(Error::Metadata)? as u64,
		)
		.ok_or(Error::LimitExceeded)?;
	for (index, entry) in snapshot.snapshot().entries.iter().enumerate() {
		for length in [
			entry.path.len(),
			snapshot
				.snapshot()
				.entry_bytes(index)
				.ok_or_else(changed)?
				.len(),
			entry.metadata.encoded_len().map_err(Error::Metadata)?,
		] {
			remaining = remaining
				.checked_sub(length as u64)
				.ok_or(Error::LimitExceeded)?;
		}
	}
	Ok(())
}
fn assign_physical(
	snapshot: &mut Snapshot<'static>,
	identities: &[Option<Identity>],
) -> Result<(), Error> {
	if identities.len() != snapshot.entries.len() {
		return Err(changed());
	}
	let mut canonical: HashMap<Identity, Vec<u8>> = HashMap::new();
	for (index, identity) in identities.iter().enumerate() {
		let Some(identity) = identity else {
			continue;
		};
		if let Some(path) = canonical.get(identity) {
			let target = snapshot.entries[..index]
				.binary_search_by(|entry| entry.path.as_ref().cmp(path))
				.map_err(|_| changed())?;
			if snapshot.entry_bytes(index) != snapshot.entry_bytes(target) {
				return Err(changed());
			}
			let path = Cow::Owned(owned(path)?);
			let entry = &mut snapshot.entries[index];
			let mut metadata = core::mem::take(&mut entry.metadata).into_metadata();
			metadata.hardlink_to = Some(path);
			entry.metadata = CanonicalMetadata::new(metadata).map_err(Error::Metadata)?;
			if let Content::FileAlias {
				target: current,
				mode: _,
			} = &mut entry.content
			{
				*current = target;
			}
		} else {
			let entry = &snapshot.entries[index];
			let group = entry
				.metadata
				.metadata()
				.hardlink_to
				.as_deref()
				.unwrap_or(&entry.path);
			let group = owned(group)?;
			canonical.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
			canonical.insert(*identity, group);
		}
	}
	Ok(())
}
fn join(prefix: &[u8], name: &[u8]) -> Result<Vec<u8>, Error> {
	let length = prefix
		.len()
		.checked_add(usize::from(!prefix.is_empty()))
		.and_then(|value| value.checked_add(name.len()))
		.ok_or(Error::LimitExceeded)?;
	if length > directory::MAX_PATH_BYTES {
		return Err(Error::LimitExceeded);
	}
	let mut path = Vec::new();
	path.try_reserve_exact(length)
		.map_err(|_| Error::OutOfMemory)?;
	path.extend_from_slice(prefix);
	if !prefix.is_empty() {
		path.push(b'/');
	}
	path.extend_from_slice(name);
	directory::validate_path(&path).map_err(Error::Snapshot)?;
	Ok(path)
}
fn changed() -> Error {
	io::Error::new(io::ErrorKind::InvalidData, "tree changed during capture").into()
}

#[cfg(target_os = "linux")]
fn hardlinked(file: &File, _omit: Omit) -> Result<bool, Error> {
	Ok(file.metadata()?.nlink() > 1)
}
#[cfg(windows)]
fn hardlinked(_file: &File, omit: Omit) -> Result<bool, Error> {
	// Windows metadata capture currently requires every family omitted. Keep
	// physical grouping unavailable until its own native adapter is qualified.
	if !omit.contains(difz_core::metadata::Family::Hardlink) {
		return Err(Error::UnsupportedMetadata);
	}
	Ok(false)
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use difz_core::path_filter::Action;
	use std::{
		fs,
		os::{fd::AsRawFd, unix::fs::symlink},
		path::Path,
		process::Command,
	};
	fn oracle(root: &Path, output: &Path, extra: &[&str]) -> [u8; 32] {
		let result = if extra.is_empty() {
			Command::new(env!("DIFZ_ORACLE"))
				.arg("--no-progress")
				.arg(root)
				.arg(root)
				.arg("-o")
				.arg(output)
				.output()
				.unwrap()
		} else {
			Command::new(env!("DIFZ_FILESYSTEM_ORACLE"))
				.arg("--directory-oracle")
				.arg(root)
				.args(extra)
				.output()
				.unwrap()
		};
		assert!(
			result.status.success(),
			"{}",
			String::from_utf8_lossy(&result.stderr)
		);
		let patch = if extra.is_empty() {
			fs::read(output).unwrap()
		} else {
			result.stdout
		};
		difz_core::tree_patch::Header::decode_prefix(
			&patch,
			difz_core::tree_patch::EnvelopeLimits::default(),
		)
		.unwrap()
		.0
		.source_hash
	}
	#[test]
	fn complete_tree_capture_matches_native_hash_filtering_hardlinks_and_pinned_root_rename() {
		let fixture = Fixture::new();
		let root = fixture.0.join("root");
		fs::create_dir(&root).unwrap();
		fs::create_dir(root.join("nested")).unwrap();
		fs::create_dir(root.join("hidden")).unwrap();
		fs::write(root.join("file"), b"binary\0\xff").unwrap();
		fs::write(root.join("nested/C:literal"), b"literal component").unwrap();
		fs::hard_link(root.join("file"), root.join("copy")).unwrap();
		symlink("../file", root.join("nested/link")).unwrap();
		let native = oracle(&root, &fixture.0.join("all.patch"), &[]);
		let directory = Directory::open(&root).unwrap();
		let captured = capture(&directory, Options::default()).unwrap();
		assert_eq!(captured.snapshot().hash(), native);
		assert!(
			captured
				.contains_directory(&directory.open_directory(b"nested").unwrap())
				.unwrap()
		);
		let moved = fixture.0.join("moved");
		fs::rename(&root, &moved).unwrap();
		fs::create_dir(&root).unwrap();
		let rules = [
			Rule {
				action: Action::Include,
				pattern: "file",
			},
			Rule {
				action: Action::Include,
				pattern: "nested/link",
			},
		];
		let selected = capture(
			&directory,
			Options {
				rules: &rules,
				..Options::default()
			},
		)
		.unwrap();
		assert!(
			selected
				.contains_directory(&directory.open_directory(b"hidden").unwrap())
				.unwrap()
		);
		assert_eq!(
			selected.snapshot().hash(),
			oracle(
				&moved,
				&fixture.0.join("selected.patch"),
				&["1", "file", "1", "nested/link"]
			)
		);
		assert!(
			selected
				.snapshot()
				.snapshot()
				.entries
				.iter()
				.find(|entry| entry.path.as_ref() == b"file")
				.unwrap()
				.metadata
				.metadata()
				.hardlink_to
				.is_none()
		);
	}
	#[test]
	fn tree_capture_bounds_all_retained_input_and_rejects_special_files_and_escaping_links() {
		let fixture = Fixture::new();
		fs::write(fixture.0.join("a"), b"x").unwrap();
		let root = Directory::open(&fixture.0).unwrap();
		let omit = Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap();
		let options = Options {
			omit,
			limits: Limits {
				bytes: 42,
				..Limits::default()
			},
			..Options::default()
		};
		assert_eq!(
			capture(&root, options)
				.unwrap()
				.snapshot()
				.snapshot()
				.entries
				.len(),
			1
		);
		assert!(matches!(
			capture(
				&root,
				Options {
					limits: Limits {
						bytes: 41,
						..options.limits
					},
					..options
				}
			),
			Err(Error::LimitExceeded)
		));
		assert!(matches!(
			capture(
				&root,
				Options {
					limits: Limits {
						entries: 0,
						..options.limits
					},
					..options
				}
			),
			Err(Error::LimitExceeded)
		));
		fs::hard_link(fixture.0.join("a"), fixture.0.join("b")).unwrap();
		let links = Options {
			omit: Omit::parse(b"xattr,acl,timestamps,finder,sparse").unwrap(),
			limits: Limits {
				bytes: 69,
				..Limits::default()
			},
			..Options::default()
		};
		assert_eq!(
			capture(&root, links)
				.unwrap()
				.snapshot()
				.snapshot()
				.entries
				.len(),
			2
		);
		assert!(matches!(
			capture(
				&root,
				Options {
					limits: Limits {
						bytes: 68,
						..links.limits
					},
					..links
				}
			),
			Err(Error::LimitExceeded)
		));
		fs::remove_file(fixture.0.join("b")).unwrap();
		assert_eq!(
			unsafe { libc::mkfifoat(root.file.as_raw_fd(), c"fifo".as_ptr(), 0o600) },
			0
		);
		assert!(matches!(
			capture(
				&root,
				Options {
					omit,
					..Options::default()
				}
			),
			Err(Error::WrongKind)
		));
		fs::remove_file(fixture.0.join("fifo")).unwrap();
		symlink("../outside", fixture.0.join("bad")).unwrap();
		assert!(matches!(
			capture(
				&root,
				Options {
					omit,
					..Options::default()
				}
			),
			Err(Error::Snapshot(directory::Error::SymlinkEscapesRoot))
		));
	}
}
