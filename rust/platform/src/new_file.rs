//! Private-stage publication of a new complete file through pinned directories.
use crate::{Directory, Error, basename, stage::Stage};
use std::io::Write;

/// Exclusive rename is the commit point. The destination is never opened or
/// truncated; unsupported no-replace rename fails without a fallback. A private
/// sibling directory protects the staging payload, including in shared parents.
pub fn publish(parent: &Directory, name: &[u8], bytes: &[u8]) -> Result<(), Error> {
	basename(name)?;
	let stage = Stage::create_unique(parent)?;
	let mut payload = stage.directory().create_file(b"payload")?;
	payload.write_all(bytes)?;
	payload.sync_all()?;
	parent.publish_file_from_stage(stage.directory(), b"payload", name)?;
	// Drop removes the now-empty owned stage. Cleanup uncertainty retains that
	// stage; it cannot remove or replace the committed destination.
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use std::{fs, os::unix::fs::symlink};
	#[test]
	fn atomic_file_publication_preserves_every_existing_kind_and_binary_or_empty_payload() {
		let fixture = Fixture::new();
		let root = Directory::open(&fixture.0).unwrap();
		publish(&root, b"data", b"binary\0\xff").unwrap();
		publish(&root, b"empty", b"").unwrap();
		fs::create_dir(fixture.0.join("directory")).unwrap();
		symlink("data", fixture.0.join("link")).unwrap();
		for name in [b"data".as_slice(), b"empty", b"directory", b"link"] {
			assert!(publish(&root, name, b"replacement").is_err());
		}
		assert_eq!(fs::read(fixture.0.join("data")).unwrap(), b"binary\0\xff");
		assert!(fs::read(fixture.0.join("empty")).unwrap().is_empty());
		assert!(
			fs::symlink_metadata(fixture.0.join("directory"))
				.unwrap()
				.is_dir()
		);
		assert!(
			fs::symlink_metadata(fixture.0.join("link"))
				.unwrap()
				.is_symlink()
		);
		assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 4);
	}
	#[test]
	fn atomic_file_publication_uses_the_open_parent_after_path_replacement() {
		let fixture = Fixture::new();
		fs::create_dir(fixture.0.join("parent")).unwrap();
		let parent = Directory::open(&fixture.0.join("parent")).unwrap();
		fs::rename(fixture.0.join("parent"), fixture.0.join("moved")).unwrap();
		fs::create_dir(fixture.0.join("parent")).unwrap();
		publish(&parent, b"data", b"pinned").unwrap();
		assert_eq!(fs::read(fixture.0.join("moved/data")).unwrap(), b"pinned");
		assert!(!fixture.0.join("parent/data").exists());
		assert!(publish(&parent, b"../escape", b"rejected").is_err());
		assert!(!fixture.0.join("escape").exists());
	}
}
