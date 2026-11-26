//! Directory patch creation; qualified platform writers provide publication.
use crate::{
	Directory, Error,
	tree_capture::{self, Options},
};
#[cfg(target_os = "linux")]
use crate::{linux_tree_write, tree_capture::Limits};
use difz_core::tree_patch::{self, CreateOptions};
#[cfg(target_os = "linux")]
use difz_core::{
	metadata::RestoreReport,
	tree_patch::{ApplyLimits, ParsedPatch},
};

/// Both trees are captured with the same selection and omissions. The returned
/// bytes use the portable v2 codec and statically linked single-threaded zstdz.
pub fn create(
	source: &Directory,
	target: &Directory,
	options: Options<'_>,
) -> Result<Vec<u8>, Error> {
	let source = tree_capture::capture(source, options)?;
	let target = tree_capture::capture(target, options)?;
	tree_patch::create(
		source.snapshot(),
		target.snapshot(),
		CreateOptions {
			rules: options.rules,
			omit: options.omit,
		},
	)
	.map_err(Error::TreePatch)
}

/// Validate patch integrity and semantics before capturing input. Its stored
/// rules and omissions select the source; callers cannot override those when
/// applying. No stage is created until source and target identities validate.
#[cfg(target_os = "linux")]
pub fn apply(
	source: &Directory,
	patch: &[u8],
	parent: &Directory,
	stage: &[u8],
	output: &[u8],
	limits: Limits,
	apply_limits: ApplyLimits,
) -> Result<RestoreReport, Error> {
	apply_named(
		source,
		patch,
		parent,
		Some(stage),
		output,
		limits,
		apply_limits,
	)
}

/// Apply using a library-owned exclusive staging name.
#[cfg(target_os = "linux")]
pub fn apply_auto(
	source: &Directory,
	patch: &[u8],
	parent: &Directory,
	output: &[u8],
	limits: Limits,
	apply_limits: ApplyLimits,
) -> Result<RestoreReport, Error> {
	apply_named(source, patch, parent, None, output, limits, apply_limits)
}
#[cfg(target_os = "linux")]
fn apply_named(
	source: &Directory,
	patch: &[u8],
	parent: &Directory,
	stage: Option<&[u8]>,
	output: &[u8],
	limits: Limits,
	apply_limits: ApplyLimits,
) -> Result<RestoreReport, Error> {
	let decoded = ParsedPatch::decode(patch, apply_limits.patch).map_err(Error::TreePatch)?;
	let omit = decoded.header().omit;
	let source = tree_capture::capture(
		source,
		Options {
			omit,
			rules: decoded.rules(),
			limits,
		},
	)?;
	let target =
		tree_patch::apply_decoded(source.snapshot(), decoded, apply_limits.max_output_bytes)
			.map_err(Error::TreePatch)?;
	match stage {
		Some(stage) => {
			linux_tree_write::publish(parent, stage, output, &target, Some(&source), omit, limits)
		}
		None => {
			linux_tree_write::publish_auto(parent, output, &target, Some(&source), omit, limits)
		}
	}
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
	use super::*;
	use crate::tests::Fixture;
	use difz_core::{
		metadata::Omit,
		path_filter::{Action, Rule},
	};
	use std::{fs, os::unix::fs::symlink, path::Path, process::Command};
	fn oracle(arguments: &[&std::ffi::OsStr]) {
		let result = Command::new(env!("DIFZ_ORACLE"))
			.args(arguments)
			.output()
			.unwrap();
		assert!(
			result.status.success(),
			"{}",
			String::from_utf8_lossy(&result.stderr)
		);
	}
	fn native_patch(source: &Path, target: &Path, patch: &Path) {
		oracle(&[
			"--no-progress".as_ref(),
			"--omit-metadata".as_ref(),
			"xattr,acl,timestamps,finder,sparse,hardlink".as_ref(),
			source.as_os_str(),
			target.as_os_str(),
			"-o".as_ref(),
			patch.as_os_str(),
		]);
	}
	#[test]
	fn complete_filesystem_patches_cross_apply_with_original_cli_and_reject_wrong_source_before_staging()
	 {
		let fixture = Fixture::new();
		let from = fixture.0.join("source");
		let to = fixture.0.join("target");
		fs::create_dir(&from).unwrap();
		fs::create_dir(&to).unwrap();
		fs::write(from.join("data"), vec![b'a'; 65_536]).unwrap();
		let mut bytes = vec![b'a'; 65_536];
		bytes[31..39].copy_from_slice(b"binary\0\xff");
		fs::write(to.join("data"), &bytes).unwrap();
		fs::create_dir(to.join("nested")).unwrap();
		fs::write(to.join("nested/new"), b"new\0\xff").unwrap();
		symlink("../data", to.join("nested/link")).unwrap();
		let omit = Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap();
		let source = Directory::open(&from).unwrap();
		let target = Directory::open(&to).unwrap();
		let rust = create(
			&source,
			&target,
			Options {
				omit,
				..Options::default()
			},
		)
		.unwrap();
		let rust_path = fixture.0.join("rust.patch");
		fs::write(&rust_path, &rust).unwrap();
		let native_path = fixture.0.join("native.patch");
		native_patch(&from, &to, &native_path);
		let native = fs::read(native_path).unwrap();
		assert_eq!(rust, native);
		let native_output = fixture.0.join("native-output");
		oracle(&[
			"--patch".as_ref(),
			"--no-progress".as_ref(),
			from.as_os_str(),
			rust_path.as_os_str(),
			"-o".as_ref(),
			native_output.as_os_str(),
		]);
		let parent = Directory::open(&fixture.0).unwrap();
		assert_eq!(
			apply(
				&source,
				&native,
				&parent,
				b"stage",
				b"rust-output",
				Limits::default(),
				ApplyLimits::default()
			)
			.unwrap()
			.bits(),
			0
		);
		let expected = tree_capture::capture(
			&target,
			Options {
				omit,
				..Options::default()
			},
		)
		.unwrap();
		for output in [&native_output, &fixture.0.join("rust-output")] {
			let actual = tree_capture::capture(
				&Directory::open(output).unwrap(),
				Options {
					omit,
					..Options::default()
				},
			)
			.unwrap();
			assert_eq!(actual.snapshot().hash(), expected.snapshot().hash());
			assert_eq!(fs::read(output.join("data")).unwrap(), bytes);
			assert_eq!(
				fs::read_link(output.join("nested/link"))
					.unwrap()
					.as_os_str()
					.as_encoded_bytes(),
				b"../data"
			);
		}
		fs::write(from.join("data"), b"wrong source").unwrap();
		assert!(matches!(
			apply(
				&source,
				&native,
				&parent,
				b"failed-stage",
				b"never-output",
				Limits::default(),
				ApplyLimits::default()
			),
			Err(Error::TreePatch(tree_patch::Error::SourceHashMismatch))
		));
		assert!(!fixture.0.join("failed-stage").exists());
		assert!(!fixture.0.join("never-output").exists());
	}
	#[test]
	fn stored_selection_drives_apply_and_invalid_patch_precedes_source_io() {
		let fixture = Fixture::new();
		let source = fixture.0.join("source");
		let target = fixture.0.join("target");
		fs::create_dir(&source).unwrap();
		fs::create_dir(&target).unwrap();
		for root in [&source, &target] {
			fs::create_dir(root.join("nested")).unwrap();
			fs::write(root.join("ignored"), b"retained").unwrap();
		}
		fs::write(source.join("nested/data"), b"before").unwrap();
		fs::write(target.join("nested/data"), b"after").unwrap();
		let source = Directory::open(&source).unwrap();
		let target = Directory::open(&target).unwrap();
		let parent = Directory::open(&fixture.0).unwrap();
		let options = Options {
			omit: Omit::parse(b"xattr,acl,timestamps,finder,sparse,hardlink").unwrap(),
			rules: &[Rule {
				action: Action::Include,
				pattern: "nested/data",
			}],
			..Options::default()
		};
		let patch = create(&source, &target, options).unwrap();
		apply(
			&source,
			&patch,
			&parent,
			b"stage",
			b"output",
			Limits::default(),
			ApplyLimits::default(),
		)
		.unwrap();
		assert_eq!(
			fs::read(fixture.0.join("output/nested/data")).unwrap(),
			b"after"
		);
		assert!(!fixture.0.join("output/ignored").exists());
		assert!(matches!(
			apply(
				&source,
				b"invalid",
				&parent,
				b"never-stage",
				b"never-output",
				Limits::default(),
				ApplyLimits::default()
			),
			Err(Error::TreePatch(tree_patch::Error::UnexpectedEndOfInput))
		));
		assert!(!fixture.0.join("never-stage").exists());
	}
}
