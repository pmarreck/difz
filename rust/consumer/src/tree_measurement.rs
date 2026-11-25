//! Resident tree-patch workloads; original CLI preparation stays outside timing.
use super::Backing;
use difz_core::{
	directory::CanonicalSnapshot,
	metadata::{Family, Omit},
	tree_patch::{self, ApplyLimits, CreateOptions},
};
use std::{
	fs,
	os::unix::fs::PermissionsExt,
	path::PathBuf,
	process::Command,
	sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Scratch(PathBuf);
impl Drop for Scratch {
	fn drop(&mut self) {
		fs::remove_dir_all(&self.0).unwrap();
	}
}
fn options() -> CreateOptions<'static> {
	let bits = Family::ALL
		.iter()
		.fold(0, |bits, family| bits | family.bit());
	CreateOptions {
		omit: Omit::from_bits(bits).unwrap(),
		..CreateOptions::default()
	}
}
pub(super) struct Prepared<'a> {
	backing: &'a Backing,
	source: CanonicalSnapshot<'a>,
	target: CanonicalSnapshot<'a>,
	native_patch: Vec<u8>,
	native_target: [u8; 32],
}
impl<'a> Prepared<'a> {
	pub(super) fn new(backing: &'a Backing) -> Self {
		assert_eq!(backing.value.len(), 2048);
		assert_eq!(backing.target_value.len(), backing.value.len());
		let source = CanonicalSnapshot::new(backing.snapshot()).unwrap();
		let target = CanonicalSnapshot::new(backing.snapshot_with(&backing.target_value)).unwrap();
		let path = std::env::temp_dir().join(format!(
			"difz-tree-probe-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		fs::create_dir(&path).unwrap(); // Refuse preexisting state; own only this creation.
		let scratch = Scratch(path);
		let from = scratch.0.join("source");
		let to = scratch.0.join("target");
		fs::create_dir(&from).unwrap();
		fs::create_dir(&to).unwrap();
		for name in &backing.names {
			let name = std::str::from_utf8(name).unwrap();
			for (directory, bytes) in [(&from, &backing.value), (&to, &backing.target_value)] {
				let path = directory.join(name);
				fs::write(&path, bytes).unwrap();
				fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
			}
		}
		let patch = scratch.0.join("native.patch");
		let output = Command::new(env!("DIFZ_ORACLE"))
			.args([
				"--no-progress",
				"--omit-metadata",
				"xattr,acl,timestamps,finder,sparse,hardlink",
			])
			.arg(&from)
			.arg(&to)
			.arg("-o")
			.arg(&patch)
			.output()
			.unwrap();
		assert!(
			output.status.success(),
			"native tree oracle failed: {:?}",
			output.stderr
		);
		let native_patch = fs::read(patch).unwrap();
		assert_eq!(&native_patch[..8], b"DIFZTREE");
		assert_eq!(&native_patch[8..10], &2u16.to_le_bytes());
		// Read the target digest directly from the documented v2 envelope, rather
		// than asking the measured parser or hasher to produce its own expectation.
		let native_target = native_patch[56..88].try_into().unwrap();
		Self {
			backing,
			source,
			target,
			native_patch,
			native_target,
		}
	}
	pub(super) fn create(&self) -> Vec<u8> {
		tree_patch::create(&self.source, &self.target, options()).unwrap()
	}
	pub(super) fn apply(&self) -> CanonicalSnapshot<'_> {
		tree_patch::apply(&self.source, &self.native_patch, ApplyLimits::default()).unwrap()
	}
	pub(super) fn correct_patch(&self, bytes: &[u8]) -> bool {
		bytes == self.native_patch
	}
	pub(super) fn correct_tree(&self, tree: &CanonicalSnapshot<'_>) -> bool {
		let snapshot = tree.snapshot();
		tree.hash() == self.native_target
			&& snapshot.root.metadata().is_empty()
			&& snapshot.entries.len() == self.backing.names.len()
			&& snapshot
				.entries
				.iter()
				.zip(&self.backing.names)
				.enumerate()
				.all(|(index, (entry, name))| {
					entry.path.as_ref() == name
						&& entry.content.kind_tag() == 2
						&& entry.content.mode().bits() == 0o644
						&& entry.metadata.metadata().is_empty()
						&& snapshot.entry_bytes(index) == Some(self.backing.target_value.as_slice())
				})
	}
}
