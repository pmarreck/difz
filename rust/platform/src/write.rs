//! Descriptor-relative mutations for private staging trees.
use crate::{Directory, EntryInfo, Error, Kind, basename};
use difz_core::directory::Mode;
use std::{
	fs::File,
	io,
	os::fd::{AsRawFd, FromRawFd},
};

impl Directory {
	/// Create with private staging permissions. Failure after creation can leave
	/// an entry for the enclosing stage guard to remove.
	pub fn create_directory(&self, name: &[u8]) -> Result<Self, Error> {
		let terminated = basename(name)?;
		// Validated basename cannot traverse; the parent handle stays live.
		check(unsafe { libc::mkdirat(self.file.as_raw_fd(), terminated.as_ptr().cast(), 0o700) })?;
		self.open_directory(name)
	}
	pub fn create_file(&self, name: &[u8]) -> Result<File, Error> {
		let name = basename(name)?;
		// O_EXCL rejects every preexisting object, including dangling symlinks.
		let fd = unsafe {
			libc::openat(
				self.file.as_raw_fd(),
				name.as_ptr().cast(),
				libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
				0o600 as libc::mode_t,
			)
		};
		if fd < 0 {
			return Err(io::Error::last_os_error().into());
		}
		// This successful open returns a fresh descriptor with exactly one owner.
		Ok(unsafe { File::from_raw_fd(fd) })
	}
	/// The tree core validates target containment using the complete entry path.
	/// This OS primitive requires a nonempty, bounded target without NUL bytes.
	pub fn create_symlink(&self, name: &[u8], target: &[u8]) -> Result<(), Error> {
		let name = basename(name)?;
		if target.is_empty()
			|| target.contains(&0)
			|| target.len() > difz_core::directory::MAX_PATH_BYTES
		{
			return Err(io::Error::new(
				io::ErrorKind::InvalidInput,
				"invalid symbolic link target",
			)
			.into());
		}
		let mut terminated = Vec::new();
		terminated
			.try_reserve_exact(target.len() + 1)
			.map_err(|_| Error::OutOfMemory)?;
		terminated.extend_from_slice(target);
		terminated.push(0);
		// Both terminated buffers and the borrowed parent descriptor are live.
		check(unsafe {
			libc::symlinkat(
				terminated.as_ptr().cast(),
				self.file.as_raw_fd(),
				name.as_ptr().cast(),
			)
		})
	}
	/// Link an earlier regular file within the private stage. Identity readback
	/// rejects a source replacement; the stage guard owns cleanup on failure.
	pub fn create_hardlink(
		&self,
		name: &[u8],
		source: &Directory,
		source_name: &[u8],
	) -> Result<(), Error> {
		let before = source.inspect(source_name)?;
		if before.kind != Kind::File {
			return Err(Error::WrongKind);
		}
		let from = basename(source_name)?;
		let to = basename(name)?;
		// Zero flags never follow a source symlink. All names are basenames.
		check(unsafe {
			libc::linkat(
				source.file.as_raw_fd(),
				from.as_ptr().cast(),
				self.file.as_raw_fd(),
				to.as_ptr().cast(),
				0,
			)
		})?;
		let after = self.inspect(name)?;
		if after.kind != Kind::File || after.identity != before.identity {
			return Err(io::Error::new(
				io::ErrorKind::InvalidData,
				"source changed during hardlink creation",
			)
			.into());
		}
		Ok(())
	}
	/// Publish an owned sibling stage. The kernel rejects a target that appears
	/// concurrently; unsupported exclusive rename is an error with no fallback.
	pub fn publish_noreplace(&self, staging: &[u8], output: &[u8]) -> Result<(), Error> {
		if staging == output {
			return Err(Error::InvalidBasename);
		}
		let from = basename(staging)?;
		let to = basename(output)?;
		if self.inspect(staging)?.kind != Kind::Directory {
			return Err(Error::WrongKind);
		}
		#[cfg(target_os = "linux")]
		let result = unsafe {
			libc::renameat2(
				self.file.as_raw_fd(),
				from.as_ptr().cast(),
				self.file.as_raw_fd(),
				to.as_ptr().cast(),
				libc::RENAME_NOREPLACE,
			)
		};
		#[cfg(target_os = "macos")]
		let result = {
			unsafe extern "C" {
				fn renameatx_np(
					from_fd: i32,
					from: *const libc::c_char,
					to_fd: i32,
					to: *const libc::c_char,
					flags: u32,
				) -> i32;
			}
			// Darwin's exclusive rename flag and ABI match the native oracle.
			unsafe {
				renameatx_np(
					self.file.as_raw_fd(),
					from.as_ptr().cast(),
					self.file.as_raw_fd(),
					to.as_ptr().cast(),
					4,
				)
			}
		};
		check(result)
	}
	/// Unlink the named leaf itself, including symlinks, without traversing it.
	pub fn remove_leaf(&self, name: &[u8]) -> Result<(), Error> {
		self.unlink(name, 0)
	}
	/// Remove only an empty directory; a symlink is rejected by the kernel.
	pub fn remove_directory(&self, name: &[u8]) -> Result<(), Error> {
		self.unlink(name, libc::AT_REMOVEDIR)
	}
	fn unlink(&self, name: &[u8], flags: i32) -> Result<(), Error> {
		let name = basename(name)?;
		check(unsafe { libc::unlinkat(self.file.as_raw_fd(), name.as_ptr().cast(), flags) })
	}
	pub fn set_mode(&self, mode: Mode) -> Result<(), Error> {
		set_mode(&self.file, mode)
	}
	/// Re-enable traversal of an owned staging child without following links.
	pub fn set_child_mode(&self, name: &[u8], mode: Mode) -> Result<(), Error> {
		match self.inspect(name)?.kind {
			Kind::File | Kind::Directory => {}
			Kind::Symlink | Kind::Other => return Err(Error::WrongKind),
		}
		let name = basename(name)?;
		check(unsafe {
			libc::fchmodat(
				self.file.as_raw_fd(),
				name.as_ptr().cast(),
				mode.bits() as libc::mode_t,
				libc::AT_SYMLINK_NOFOLLOW,
			)
		})
	}
}
pub fn set_mode(file: &File, mode: Mode) -> Result<(), Error> {
	match EntryInfo::for_file(file)?.kind {
		Kind::File | Kind::Directory => {}
		Kind::Symlink | Kind::Other => return Err(Error::WrongKind),
	}
	// Mode is already constrained to the portable permission bits.
	check(unsafe { libc::fchmod(file.as_raw_fd(), mode.bits() as libc::mode_t) })
}
fn check(result: i32) -> Result<(), Error> {
	if result == 0 {
		Ok(())
	} else {
		Err(io::Error::last_os_error().into())
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use std::{
		fs,
		io::Write,
		os::unix::fs::{MetadataExt, PermissionsExt},
	};
	#[test]
	fn exclusive_creation_preserves_binary_bytes_modes_and_existing_objects() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		let child = root.create_directory(b"sub").unwrap();
		let mut file = child.create_file(b"data").unwrap();
		file.write_all(b"\0\xffbytes").unwrap();
		assert_eq!(
			fs::read(fixture.0.join("sub/data")).unwrap(),
			b"\0\xffbytes"
		);
		assert!(child.create_file(b"data").is_err());
		assert!(root.create_directory(b"sub").is_err());
		assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o600);
		assert_eq!(
			fs::metadata(fixture.0.join("sub"))
				.unwrap()
				.permissions()
				.mode() & 0o777,
			0o700
		);
		child.create_symlink(b"alias", b"data").unwrap();
		assert_eq!(
			fs::read_link(fixture.0.join("sub/alias"))
				.unwrap()
				.as_os_str()
				.as_encoded_bytes(),
			b"data"
		);
		assert!(child.create_file(b"alias").is_err());
		for target in [b"".as_slice(), b"bad\0target"] {
			assert!(child.create_symlink(b"invalid", target).is_err());
		}
		assert!(!fixture.0.join("sub/invalid").exists());
		for name in [b"../escape".as_slice(), b"a/b", b"nul\0tail"] {
			assert!(root.create_file(name).is_err());
		}
		set_mode(&file, Mode::from_bits(0o444).unwrap()).unwrap();
		assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o444);
	}
	#[test]
	fn hardlink_readback_matches_independent_inode_identity_and_rejects_other_kinds() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		root.create_file(b"data")
			.unwrap()
			.write_all(b"payload")
			.unwrap();
		let child = root.create_directory(b"sub").unwrap();
		child.create_hardlink(b"alias", &root, b"data").unwrap();
		let original = fs::metadata(fixture.0.join("data")).unwrap();
		let alias = fs::metadata(fixture.0.join("sub/alias")).unwrap();
		assert_eq!((original.dev(), original.ino()), (alias.dev(), alias.ino()));
		assert!(original.nlink() >= 2);
		assert!(child.create_hardlink(b"alias", &root, b"data").is_err());
		root.create_symlink(b"symbolic", b"data").unwrap();
		for source in [b"symbolic".as_slice(), b"sub"] {
			assert!(matches!(
				child.create_hardlink(b"bad", &root, source),
				Err(Error::WrongKind)
			));
		}
		assert!(!fixture.0.join("sub/bad").exists());
	}
	#[test]
	fn exclusive_publication_preserves_occupied_targets_and_moves_the_complete_stage() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		let stage = root.create_directory(b"stage").unwrap();
		stage
			.create_file(b"data")
			.unwrap()
			.write_all(b"staged")
			.unwrap();
		root.create_directory(b"occupied-dir").unwrap();
		root.create_file(b"occupied-file")
			.unwrap()
			.write_all(b"existing")
			.unwrap();
		root.create_symlink(b"occupied-link", b"occupied-file")
			.unwrap();
		for output in [
			b"occupied-dir".as_slice(),
			b"occupied-file",
			b"occupied-link",
			b"stage",
		] {
			assert!(root.publish_noreplace(b"stage", output).is_err());
			assert_eq!(fs::read(fixture.0.join("stage/data")).unwrap(), b"staged");
		}
		assert_eq!(
			fs::read(fixture.0.join("occupied-file")).unwrap(),
			b"existing"
		);
		assert!(
			fs::symlink_metadata(fixture.0.join("occupied-link"))
				.unwrap()
				.is_symlink()
		);
		root.publish_noreplace(b"stage", b"published").unwrap();
		assert!(!fixture.0.join("stage").exists());
		assert_eq!(
			fs::read(fixture.0.join("published/data")).unwrap(),
			b"staged"
		);
	}
	#[test]
	fn mutations_keep_the_open_parent_when_its_path_is_replaced() {
		let fixture = Fixture::new();
		fs::create_dir(fixture.0.join("parent")).unwrap();
		let root = Directory::open(&fixture.0.join("parent")).unwrap();
		fs::rename(fixture.0.join("parent"), fixture.0.join("moved")).unwrap();
		fs::create_dir(fixture.0.join("parent")).unwrap();
		root.create_file(b"kept")
			.unwrap()
			.write_all(b"pinned")
			.unwrap();
		assert_eq!(fs::read(fixture.0.join("moved/kept")).unwrap(), b"pinned");
		assert!(!fixture.0.join("parent/kept").exists());
		root.remove_leaf(b"kept").unwrap();
		assert!(!fixture.0.join("moved/kept").exists());
	}
	#[test]
	fn removal_never_follows_links_and_requires_empty_directories() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		let child = root.create_directory(b"sub").unwrap();
		child
			.create_file(b"data")
			.unwrap()
			.write_all(b"retained")
			.unwrap();
		root.create_symlink(b"alias", b"sub").unwrap();
		assert!(root.remove_directory(b"alias").is_err());
		assert!(root.remove_directory(b"sub").is_err());
		root.remove_leaf(b"alias").unwrap();
		assert_eq!(fs::read(fixture.0.join("sub/data")).unwrap(), b"retained");
		child.remove_leaf(b"data").unwrap();
		root.remove_directory(b"sub").unwrap();
		assert!(!fixture.0.join("sub").exists());
	}
}
