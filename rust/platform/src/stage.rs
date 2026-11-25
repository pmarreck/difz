//! Owned staging lifetime and bounded, iterative cleanup without link traversal.
use crate::{Directory, Error, Identity, Kind, Names, basename};
use difz_core::directory::{MAX_ENTRIES, MAX_PATH_BYTES, Mode};
use std::io;
const WRITABLE: Mode = match Mode::from_bits(0o700) {
	Ok(mode) => mode,
	Err(_) => panic!("invalid private directory mode"),
};

pub struct Stage<'a> {
	parent: &'a Directory,
	name: Vec<u8>,
	directory: Directory,
	identity: Identity,
	finished: bool,
}
impl<'a> Stage<'a> {
	/// The caller chooses a unique sibling name. Existing entries are preserved.
	pub fn create(parent: &'a Directory, name: &[u8]) -> Result<Self, Error> {
		Self::create_with(parent, name, Directory::inspect_self)
	}
	fn create_with(
		parent: &'a Directory,
		name: &[u8],
		inspect: impl FnOnce(&Directory) -> Result<crate::EntryInfo, Error>,
	) -> Result<Self, Error> {
		let stored = basename(name)?;
		let directory = parent.create_directory(name)?;
		// Until identity is known, an error cannot establish that this name
		// still belongs to us. Retain the entry rather than unlink a replacement.
		let identity = inspect(&directory)?.identity;
		Ok(Self {
			parent,
			name: stored,
			directory,
			identity,
			finished: false,
		})
	}
	pub fn directory(&self) -> &Directory {
		&self.directory
	}
	pub fn name(&self) -> &[u8] {
		&self.name[..self.name.len() - 1]
	}
	pub fn publish(mut self, output: &[u8]) -> Result<(), Error> {
		self.check_identity()?;
		self.parent.publish_noreplace(self.name(), output)?;
		self.finished = true;
		Ok(())
	}
	pub fn cleanup(&mut self) -> Result<(), Error> {
		if self.finished {
			return Ok(());
		}
		self.check_identity()?;
		clear(&self.directory)?;
		self.check_identity()?;
		self.parent.remove_directory(self.name())?;
		self.finished = true;
		Ok(())
	}
	fn check_identity(&self) -> Result<(), Error> {
		let actual = self.parent.inspect(self.name())?;
		if actual.kind != Kind::Directory || actual.identity != self.identity {
			return Err(changed());
		}
		Ok(())
	}
}
impl Drop for Stage<'_> {
	fn drop(&mut self) {
		// Explicit cleanup reports errors. Drop makes a final bounded attempt;
		// uncertain/replaced entries are retained instead of deleting other work.
		let _ = self.cleanup();
	}
}
enum Handle<'a> {
	Root(&'a Directory),
	Child(Directory),
}
impl Handle<'_> {
	fn directory(&self) -> &Directory {
		match self {
			Self::Root(dir) => dir,
			Self::Child(dir) => dir,
		}
	}
}
struct Frame<'a> {
	handle: Handle<'a>,
	names: Names,
	name: Vec<u8>,
	identity: Identity,
}
fn frame<'a>(handle: Handle<'a>, name: Vec<u8>) -> Result<Frame<'a>, Error> {
	let directory = handle.directory();
	directory.set_mode(WRITABLE)?;
	let identity = directory.inspect_self()?.identity;
	let names = directory.names(MAX_ENTRIES, MAX_PATH_BYTES)?;
	Ok(Frame {
		handle,
		names,
		name,
		identity,
	})
}
fn clear(root: &Directory) -> Result<(), Error> {
	let mut stack = Vec::new();
	stack.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
	stack.push(frame(Handle::Root(root), Vec::new())?);
	let mut remaining = MAX_ENTRIES;
	while let Some(current) = stack.last_mut() {
		if let Some(name) = current.names.next() {
			let name = name?;
			remaining = remaining.checked_sub(1).ok_or(Error::LimitExceeded)?;
			let parent = current.handle.directory();
			let info = parent.inspect(&name)?;
			match info.kind {
				Kind::Directory => {
					parent.set_child_mode(&name, WRITABLE)?;
					let child = parent.open_directory(&name)?;
					if child.inspect_self()?.identity != info.identity {
						return Err(changed());
					}
					let next = frame(Handle::Child(child), name)?;
					stack.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
					stack.push(next);
				}
				Kind::File | Kind::Symlink | Kind::Other => parent.remove_leaf(&name)?,
			}
		} else {
			let done = stack.pop().ok_or_else(changed)?;
			if let Some(parent) = stack.last() {
				let directory = parent.handle.directory();
				if directory.inspect(&done.name)?.identity != done.identity {
					return Err(changed());
				}
				directory.remove_directory(&done.name)?;
			}
		}
	}
	Ok(())
}
fn changed() -> Error {
	io::Error::new(io::ErrorKind::InvalidData, "owned staging identity changed").into()
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use std::{fs, io::Write};
	#[test]
	fn failed_initial_inspection_retains_a_replacement_instead_of_deleting_it() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		let result = Stage::create_with(&parent, b"stage", |_| {
			fs::rename(fixture.0.join("stage"), fixture.0.join("moved")).unwrap();
			fs::create_dir(fixture.0.join("stage")).unwrap();
			Err(io::Error::new(io::ErrorKind::Other, "injected inspection failure").into())
		});
		assert!(result.is_err());
		assert!(fixture.0.join("stage").is_dir());
		assert!(fixture.0.join("moved").is_dir());
	}
	#[test]
	fn dropping_a_stage_cleans_restricted_directories_without_following_symlinks() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		parent
			.create_file(b"outside")
			.unwrap()
			.write_all(b"retained")
			.unwrap();
		{
			let stage = Stage::create(&parent, b".difz-stage-owned").unwrap();
			let child = stage.directory().create_directory(b"restricted").unwrap();
			child
				.create_file(b"data")
				.unwrap()
				.write_all(b"scratch")
				.unwrap();
			stage
				.directory()
				.create_symlink(b"link", b"../outside")
				.unwrap();
			child.set_mode(Mode::from_bits(0).unwrap()).unwrap();
		}
		assert!(!fixture.0.join(".difz-stage-owned").exists());
		assert_eq!(fs::read(fixture.0.join("outside")).unwrap(), b"retained");
	}
	#[test]
	fn replaced_stage_names_are_retained_and_successful_publication_disarms_cleanup() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		let mut stage = Stage::create(&parent, b"stage").unwrap();
		fs::rename(fixture.0.join("stage"), fixture.0.join("moved")).unwrap();
		fs::create_dir(fixture.0.join("stage")).unwrap();
		fs::write(fixture.0.join("stage/other-work"), b"retained").unwrap();
		assert!(stage.cleanup().is_err());
		drop(stage);
		assert_eq!(
			fs::read(fixture.0.join("stage/other-work")).unwrap(),
			b"retained"
		);
		let stage = Stage::create(&parent, b"fresh").unwrap();
		stage
			.directory()
			.create_file(b"data")
			.unwrap()
			.write_all(b"published")
			.unwrap();
		stage.publish(b"output").unwrap();
		assert_eq!(
			fs::read(fixture.0.join("output/data")).unwrap(),
			b"published"
		);
	}
	#[test]
	fn occupied_publication_target_is_preserved_and_failed_stage_is_removed() {
		let fixture = Fixture::new();
		let parent = Directory::open(&fixture.0).unwrap();
		parent
			.create_file(b"occupied")
			.unwrap()
			.write_all(b"retained")
			.unwrap();
		let stage = Stage::create(&parent, b"stage").unwrap();
		stage.directory().create_file(b"data").unwrap();
		assert!(stage.publish(b"occupied").is_err());
		assert_eq!(fs::read(fixture.0.join("occupied")).unwrap(), b"retained");
		assert!(!fixture.0.join("stage").exists());
	}
}
