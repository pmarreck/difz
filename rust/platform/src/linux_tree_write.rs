//! Restore a validated target into an owned sibling stage, verify, then publish.
use crate::{
	Directory, Error, linux_snapshot_metadata,
	linux_stage_metadata::restore as ordinary,
	linux_symlink_restore,
	linux_tree_capture::{self, Captured, Limits, Options},
	stage::Stage,
	xattr,
};
use difz_core::{
	directory::{CanonicalSnapshot, Content, Mode},
	metadata::{CanonicalMetadata, CompromiseCode, Metadata, Omit, RestoreReport},
	symlink_transport::{Record, Transport},
};
use std::{
	collections::HashMap,
	io::{self, Write},
};

/// No existing output is replaced. Source membership is checked before creating
/// the stage, including directories excluded by the source's selection rules.
/// Every object is created privately before metadata and final permissions.
/// Verification re-captures the whole stage through the ordinary reader.
pub fn publish(
	parent: &Directory,
	stage_name: &[u8],
	output_name: &[u8],
	target: &CanonicalSnapshot<'_>,
	source: Option<&Captured>,
	omit: Omit,
	limits: Limits,
) -> Result<RestoreReport, Error> {
	publish_named(
		parent,
		Some(stage_name),
		output_name,
		target,
		source,
		omit,
		limits,
	)
}

/// Choose an exclusive private stage name for public API and CLI callers.
pub fn publish_auto(
	parent: &Directory,
	output_name: &[u8],
	target: &CanonicalSnapshot<'_>,
	source: Option<&Captured>,
	omit: Omit,
	limits: Limits,
) -> Result<RestoreReport, Error> {
	publish_named(parent, None, output_name, target, source, omit, limits)
}
fn publish_named(
	parent: &Directory,
	stage_name: Option<&[u8]>,
	output_name: &[u8],
	target: &CanonicalSnapshot<'_>,
	source: Option<&Captured>,
	omit: Omit,
	limits: Limits,
) -> Result<RestoreReport, Error> {
	crate::basename(output_name)?;
	if stage_name == Some(output_name) {
		return Err(Error::InvalidBasename);
	}
	if let Some(source) = source {
		if source.contains_directory(parent)? {
			return Err(invalid("output parent is inside the captured source"));
		}
	}
	preflight(target, omit, limits)?;
	let stage = match stage_name {
		Some(name) => Stage::create(parent, name)?,
		None => Stage::create_unique(parent)?,
	};
	let copied = create(stage.directory(), target)?;
	let report = restore(stage.directory(), target, &copied, omit, limits.metadata)?;
	let actual = linux_tree_capture::capture(
		stage.directory(),
		Options {
			omit,
			rules: &[],
			limits,
		},
	)?;
	if actual.snapshot().hash() != target.hash() {
		return Err(invalid("staged tree differs from the requested target"));
	}
	stage.publish(output_name)?;
	Ok(report)
}

fn preflight(target: &CanonicalSnapshot<'_>, omit: Omit, limits: Limits) -> Result<(), Error> {
	let snapshot = target.snapshot();
	if snapshot.entries.len() > limits.entries {
		return Err(Error::LimitExceeded);
	}
	let mut used = 0u64;
	for (index, entry) in snapshot.entries.iter().enumerate() {
		let data = snapshot
			.entry_bytes(index)
			.ok_or_else(|| invalid("invalid canonical content"))?;
		for length in [entry.path.len(), data.len()] {
			used = used
				.checked_add(length as u64)
				.ok_or(Error::LimitExceeded)?;
		}
		validate_metadata(
			&entry.metadata,
			omit,
			limits.metadata,
			matches!(entry.content, Content::Symlink { .. }),
		)?;
		used = used
			.checked_add(entry.metadata.encoded_len().map_err(Error::Metadata)? as u64)
			.ok_or(Error::LimitExceeded)?;
	}
	validate_metadata(&snapshot.root, omit, limits.metadata, false)?;
	used = used
		.checked_add(snapshot.root.encoded_len().map_err(Error::Metadata)? as u64)
		.ok_or(Error::LimitExceeded)?;
	if used > limits.bytes {
		return Err(Error::LimitExceeded);
	}
	Ok(())
}
fn validate_metadata(
	value: &CanonicalMetadata<'_>,
	omit: Omit,
	limits: linux_snapshot_metadata::Limits,
	symlink: bool,
) -> Result<(), Error> {
	if value.metadata().xattrs.len() > limits.attributes
		|| value.metadata().holes.len() > limits.extents
		|| value.encoded_len().map_err(Error::Metadata)? > limits.metadata_bytes
	{
		return Err(Error::LimitExceeded);
	}
	if value
		.borrowing_omitting(omit)
		.map_err(Error::Metadata)?
		.hash()
		!= value.hash()
	{
		return Err(invalid("target contains an omitted metadata family"));
	}
	if !symlink && value.metadata().times.atime.is_some() {
		return Err(io::Error::new(
			io::ErrorKind::Unsupported,
			"access time is outside the native snapshot profile",
		)
		.into());
	}
	Ok(())
}

fn create(root: &Directory, target: &CanonicalSnapshot<'_>) -> Result<Vec<bool>, Error> {
	let snapshot = target.snapshot();
	let mut copied = Vec::new();
	copied
		.try_reserve_exact(snapshot.entries.len())
		.map_err(|_| Error::OutOfMemory)?;
	copied.resize(snapshot.entries.len(), false);
	for (index, entry) in snapshot.entries.iter().enumerate() {
		let (parent, name) = open_parent(root, &entry.path)?;
		match &entry.content {
			Content::Directory { .. } => {
				parent.create_directory(name)?;
			}
			Content::File { bytes, .. } => parent.create_file(name)?.write_all(bytes)?,
			Content::Symlink { target } => parent.create_symlink(name, target)?,
			Content::FileAlias { target, .. } => {
				let path = &snapshot.entries[*target].path;
				let (from, from_name) = open_parent(root, path)?;
				match parent.create_hardlink(name, &from, from_name) {
					Ok(()) => {}
					Err(Error::Io(error))
						if matches!(
							error.raw_os_error(),
							Some(
								libc::EPERM
									| libc::EACCES | libc::ENOTSUP
									| libc::EXDEV | libc::EMLINK
							)
						) =>
					{
						parent.create_file(name)?.write_all(
							snapshot
								.entry_bytes(index)
								.ok_or_else(|| invalid("invalid file alias"))?,
						)?;
						copied[index] = true;
					}
					Err(error) => return Err(error),
				}
			}
		}
	}
	Ok(copied)
}

fn restore<'a>(
	root: &Directory,
	target: &'a CanonicalSnapshot<'_>,
	copied: &[bool],
	omit: Omit,
	limits: linux_snapshot_metadata::Limits,
) -> Result<RestoreReport, Error> {
	let mut report = RestoreReport::default();
	let mut parents: HashMap<&[u8], Vec<Record<'a>>> = HashMap::new();
	// Every ancestor precedes its children in canonical path order. Reversing
	// it finalizes each directory only after all descendants and parent records.
	for (index, entry) in target.snapshot().entries.iter().enumerate().rev() {
		let (parent, name) = open_parent(root, &entry.path)?;
		match &entry.content {
			Content::Directory { mode } => {
				let child = parent.open_directory(name)?;
				store_parent(&child, parents.remove(entry.path.as_ref()), &mut report)?;
				ordinary(
					&child.file,
					&entry.metadata,
					*mode,
					false,
					omit,
					limits,
					&mut report,
				)?;
			}
			Content::File { mode, .. } => ordinary(
				&parent.open_staging_file(name)?,
				&entry.metadata,
				*mode,
				true,
				omit,
				limits,
				&mut report,
			)?,
			Content::FileAlias { mode, .. } => {
				if copied[index] {
					let file = parent.open_staging_file(name)?;
					let metadata = CanonicalMetadata::new(Metadata {
						hardlink_to: entry
							.metadata
							.borrowing_omitting(Omit::default())
							.map_err(Error::Metadata)?
							.into_metadata()
							.hardlink_to,
						..Metadata::default()
					})
					.map_err(Error::Metadata)?;
					xattr::set(
						&file,
						b"user.difz.hardlink-to",
						&metadata.encode().map_err(Error::Metadata)?,
					)?;
					ordinary(
						&file,
						&entry.metadata,
						*mode,
						true,
						omit,
						limits,
						&mut report,
					)?;
					report.add(CompromiseCode::HardlinkCopied);
				}
			}
			Content::Symlink { .. } => {
				if let Some(record) =
					linux_symlink_restore::prepare(&parent, name, &entry.metadata, omit, limits)?
				{
					let prefix = parent_path(&entry.path);
					if !parents.contains_key(prefix) {
						parents.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
						parents.insert(prefix, Vec::new());
					}
					let records = parents
						.get_mut(prefix)
						.ok_or_else(|| invalid("missing parent transport bucket"))?;
					records.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
					records.push(record);
				}
			}
		}
	}
	store_parent(root, parents.remove(b"".as_slice()), &mut report)?;
	if !parents.is_empty() {
		return Err(invalid("unwritten parent transport"));
	}
	ordinary(
		&root.file,
		&target.snapshot().root,
		Mode::from_bits(0o700).map_err(Error::Snapshot)?,
		false,
		omit,
		limits,
		&mut report,
	)?;
	Ok(report)
}
fn store_parent(
	parent: &Directory,
	records: Option<Vec<Record<'_>>>,
	report: &mut RestoreReport,
) -> Result<(), Error> {
	if let Some(mut records) = records {
		records.sort_unstable_by(|left, right| left.name.cmp(&right.name));
		let bytes = Transport::new(records)
			.map_err(Error::Transport)?
			.encode()
			.map_err(Error::Transport)?;
		xattr::set(&parent.file, b"user.difz.symlinks", &bytes)?;
		report.add(CompromiseCode::SymlinkMetadataPreserved);
	}
	Ok(())
}
fn open_parent<'a>(root: &Directory, path: &'a [u8]) -> Result<(Directory, &'a [u8]), Error> {
	let prefix = parent_path(path);
	let mut directory = Directory {
		file: root.file.try_clone()?,
	};
	if !prefix.is_empty() {
		for part in prefix.split(|&byte| byte == b'/') {
			directory = directory.open_directory(part)?;
		}
	}
	let name = &path[if prefix.is_empty() {
		0
	} else {
		prefix.len() + 1
	}..];
	Ok((directory, name))
}
fn parent_path(path: &[u8]) -> &[u8] {
	path.iter()
		.rposition(|&byte| byte == b'/')
		.map_or(&[], |index| &path[..index])
}
fn invalid(message: &'static str) -> Error {
	io::Error::new(io::ErrorKind::InvalidData, message).into()
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use difz_core::{
		directory::{Entry, Snapshot},
		metadata::{Time, Times, Xattr, XattrClass},
	};
	use std::{
		borrow::Cow,
		fs::{self, File},
		io::{Seek, SeekFrom},
		os::unix::fs::{MetadataExt, PermissionsExt, symlink},
		path::Path,
		process::Command,
	};
	fn all_omitted() -> Omit {
		Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap()
	}
	fn basic() -> CanonicalSnapshot<'static> {
		CanonicalSnapshot::new(Snapshot {
			entries: vec![
				Entry {
					path: Cow::Borrowed(b"a"),
					content: Content::Directory {
						mode: Mode::from_bits(0o500).unwrap(),
					},
					metadata: CanonicalMetadata::default(),
				},
				Entry {
					path: Cow::Borrowed(b"a/data"),
					content: Content::File {
						mode: Mode::from_bits(0o444).unwrap(),
						bytes: Cow::Borrowed(b"binary\0\xff"),
					},
					metadata: CanonicalMetadata::default(),
				},
				Entry {
					path: Cow::Borrowed(b"link"),
					content: Content::Symlink {
						target: Cow::Borrowed(b"a/data"),
					},
					metadata: CanonicalMetadata::default(),
				},
			],
			root: CanonicalMetadata::default(),
		})
		.unwrap()
	}
	fn native_hash(root: &Path) -> [u8; 32] {
		let output = Command::new(env!("DIFZ_FILESYSTEM_ORACLE"))
			.arg("--directory-oracle")
			.arg(root)
			.output()
			.unwrap();
		assert!(
			output.status.success(),
			"{}",
			String::from_utf8_lossy(&output.stderr)
		);
		difz_core::tree_patch::Header::decode_prefix(
			&output.stdout,
			difz_core::tree_patch::EnvelopeLimits::default(),
		)
		.unwrap()
		.0
		.source_hash
	}
	#[test]
	fn staged_writer_preserves_bytes_modes_links_and_occupied_output_without_native_metadata() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		let target = basic();
		assert_eq!(
			publish(
				&root,
				b"stage",
				b"output",
				&target,
				None,
				all_omitted(),
				Limits::default()
			)
			.unwrap()
			.bits(),
			0
		);
		assert_eq!(
			fs::read(fixture.0.join("output/a/data")).unwrap(),
			b"binary\0\xff"
		);
		assert_eq!(
			fs::metadata(fixture.0.join("output/a"))
				.unwrap()
				.permissions()
				.mode() & 0o777,
			0o500
		);
		fs::set_permissions(
			fixture.0.join("output/a"),
			fs::Permissions::from_mode(0o700),
		)
		.unwrap();
		assert_eq!(
			fs::metadata(fixture.0.join("output/a/data"))
				.unwrap()
				.permissions()
				.mode() & 0o777,
			0o444
		);
		assert_eq!(
			fs::read_link(fixture.0.join("output/link"))
				.unwrap()
				.as_os_str()
				.as_encoded_bytes(),
			b"a/data"
		);
		fs::write(fixture.0.join("occupied"), b"retained").unwrap();
		assert!(
			publish(
				&root,
				b"other-stage",
				b"occupied",
				&target,
				None,
				all_omitted(),
				Limits::default()
			)
			.is_err()
		);
		assert_eq!(fs::read(fixture.0.join("occupied")).unwrap(), b"retained");
		assert!(!fixture.0.join("other-stage").exists());
		assert!(!fixture.0.join("stage").exists());
	}
	#[test]
	fn source_membership_and_input_limits_fail_before_creating_a_stage() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		let hidden = root.create_directory(b"hidden").unwrap();
		let source = linux_tree_capture::capture(
			&root,
			Options {
				omit: all_omitted(),
				..Options::default()
			},
		)
		.unwrap();
		let target = basic();
		assert!(
			publish(
				&hidden,
				b"stage",
				b"output",
				&target,
				Some(&source),
				all_omitted(),
				Limits::default()
			)
			.is_err()
		);
		assert!(!fixture.0.join("hidden/stage").exists());
		for limits in [
			Limits {
				entries: 2,
				..Limits::default()
			},
			Limits {
				bytes: 0,
				..Limits::default()
			},
		] {
			assert!(matches!(
				publish(
					&root,
					b"stage",
					b"output",
					&target,
					None,
					all_omitted(),
					limits
				),
				Err(Error::LimitExceeded)
			));
			assert!(!fixture.0.join("stage").exists());
		}
	}
	#[test]
	fn native_parent_transport_restores_a_literal_drive_prefix_link_component() {
		let fixture = Fixture::new();
		let mut raw = basic().into_snapshot();
		raw.entries[0].content = Content::Directory {
			mode: Mode::from_bits(0o700).unwrap(),
		};
		raw.entries[2].path = Cow::Borrowed(b"a/C:link");
		raw.entries[2].content = Content::Symlink {
			target: Cow::Borrowed(b"data"),
		};
		raw.entries[2].metadata = CanonicalMetadata::new(Metadata {
			xattrs: vec![Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"comment"),
				value: Cow::Borrowed(b"preserved\0\xff"),
			}],
			..Metadata::default()
		})
		.unwrap();
		raw.entries
			.sort_unstable_by(|left, right| left.path.cmp(&right.path));
		let target = CanonicalSnapshot::new(raw).unwrap();
		let parent = Directory::open(&fixture.0).unwrap();
		publish_auto(
			&parent,
			b"output",
			&target,
			None,
			Omit::default(),
			Limits::default(),
		)
		.unwrap();
		assert_eq!(
			fs::read_link(fixture.0.join("output/a/C:link"))
				.unwrap()
				.as_os_str()
				.as_encoded_bytes(),
			b"data"
		);
		assert_eq!(
			fs::read(fixture.0.join("output/a/data")).unwrap(),
			b"binary\0\xff"
		);
		let actual = linux_tree_capture::capture(
			&Directory::open(&fixture.0.join("output")).unwrap(),
			Options::default(),
		)
		.unwrap();
		assert_eq!(actual.snapshot().hash(), target.hash());
		let directory = Directory::open(&fixture.0.join("output/a")).unwrap();
		let mut bytes = [0u8; 65_536];
		use std::os::fd::AsRawFd;
		let count = unsafe {
			libc::fgetxattr(
				directory.file.as_raw_fd(),
				c"user.difz.symlinks".as_ptr(),
				bytes.as_mut_ptr().cast(),
				bytes.len(),
			)
		};
		assert!(count > 0);
		let bytes = &bytes[..count as usize];
		assert!(bytes.windows(6).any(|part| part == b"C:link"));
		assert!(bytes.windows(11).any(|part| part == b"preserved\0\xff"));
	}
	#[test]
	fn native_staged_writer_matches_original_abi_hash_and_preserves_physical_hardlinks_and_symlink_transport()
	 {
		let fixture = Fixture::new();
		let input = fixture.0.join("input");
		fs::create_dir(&input).unwrap();
		fs::create_dir(input.join("nested")).unwrap();
		fs::write(input.join("a"), b"binary\0\xff").unwrap();
		let mut hole = File::create(input.join("hole")).unwrap();
		hole.seek(SeekFrom::Start(65_535)).unwrap();
		hole.write_all(b"x").unwrap();
		fs::hard_link(input.join("a"), input.join("nested/alias")).unwrap();
		symlink("../a", input.join("nested/link")).unwrap();
		let source_dir = Directory::open(&input).unwrap();
		let file = source_dir.open_regular_file(b"a").unwrap();
		xattr::set(&file, b"user.data", b"binary\0\xffattribute").unwrap();
		let child = source_dir.open_directory(b"nested").unwrap();
		let link_metadata = CanonicalMetadata::new(Metadata {
			xattrs: vec![Xattr {
				class: XattrClass::Logical,
				name: Cow::Borrowed(b"name"),
				value: Cow::Borrowed(b"link\0value"),
			}],
			finder_flags: 7,
			finder_info: Some([0xa5; 32]),
			times: Times {
				mtime: Some(Time { sec: -7, nsec: 13 }),
				atime: None,
				btime: None,
			},
			..Metadata::default()
		})
		.unwrap();
		let record = linux_symlink_restore::prepare(
			&child,
			b"link",
			&link_metadata,
			Omit::default(),
			linux_snapshot_metadata::Limits::default(),
		)
		.unwrap()
		.unwrap();
		store_parent(&child, Some(vec![record]), &mut RestoreReport::default()).unwrap();
		child.set_mode(Mode::from_bits(0o500).unwrap()).unwrap();
		let source = linux_tree_capture::capture(&source_dir, Options::default()).unwrap();
		assert_eq!(source.snapshot().hash(), native_hash(&input));
		let parent = Directory::open(&fixture.0).unwrap();
		let report = publish(
			&parent,
			b"stage",
			b"output",
			source.snapshot(),
			Some(&source),
			Omit::default(),
			Limits::default(),
		)
		.unwrap();
		assert_ne!(
			report.bits() & (1 << (CompromiseCode::SymlinkMetadataPreserved as u8 - 1)),
			0
		);
		assert_eq!(
			native_hash(&fixture.0.join("output")),
			source.snapshot().hash()
		);
		let expected_holes = &source
			.snapshot()
			.snapshot()
			.entries
			.iter()
			.find(|entry| entry.path.as_ref() == b"hole")
			.unwrap()
			.metadata
			.metadata()
			.holes;
		assert!(!expected_holes.is_empty());
		assert_eq!(
			crate::sparse::capture(File::open(fixture.0.join("output/hole")).unwrap(), 100)
				.unwrap(),
			*expected_holes
		);
		assert_eq!(
			report.bits() & (1 << (CompromiseCode::SparsePreserved as u8 - 1)),
			0
		);
		// The fixture owns these published read-only directories. Restore their
		// write permissions after all fidelity checks so fixture removal succeeds.
		for path in [input.join("nested"), fixture.0.join("output/nested")] {
			fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
		}
		let a = fs::metadata(fixture.0.join("output/a")).unwrap();
		let alias = fs::metadata(fixture.0.join("output/nested/alias")).unwrap();
		assert_eq!((a.dev(), a.ino()), (alias.dev(), alias.ino()));
		assert_ne!(
			(a.dev(), a.ino()),
			(
				file.metadata().unwrap().dev(),
				file.metadata().unwrap().ino()
			)
		);
		assert_eq!(
			xattr::get(&file, b"user.data", 65_536).unwrap().unwrap(),
			b"binary\0\xffattribute"
		);
		assert!(!fixture.0.join("stage").exists());
	}
}
