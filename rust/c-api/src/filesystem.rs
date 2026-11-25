//! Guarded pointer/length filesystem entry points. No input is retained.
use super::{Buffer, Status, guard, produce};

#[repr(C)]
pub struct Rule {
	pub action: u8,
	pub pattern: *const u8,
	pub pattern_len: usize,
}

/// # Safety
/// All borrowed byte regions satisfy difz-rust.h and remain live for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_new_file_publish(
	parent: *const u8,
	parent_len: usize,
	name: *const u8,
	name_len: usize,
	bytes: *const u8,
	length: usize,
) -> i32 {
	guard(|| {
		#[cfg(target_os = "linux")]
		{
			unsafe { linux::publish_file(parent, parent_len, name, name_len, bytes, length) }
		}
		#[cfg(not(target_os = "linux"))]
		{
			let _ = (parent, parent_len, name, name_len, bytes, length);
			Err(Status::Unsupported)
		}
	})
}

/// # Safety
/// Borrowed regions and the disjoint writable output satisfy difz-rust.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_directory_encode(
	source: *const u8,
	source_len: usize,
	target: *const u8,
	target_len: usize,
	rules: *const Rule,
	rule_count: usize,
	omit: u32,
	max_snapshot_bytes: u64,
	max_patch_bytes: u64,
	out: *mut *mut Buffer,
) -> i32 {
	// Produce publishes the opaque allocation only after the complete operation.
	unsafe {
		produce(out, || {
			#[cfg(target_os = "linux")]
			{
				linux::encode(
					source,
					source_len,
					target,
					target_len,
					rules,
					rule_count,
					omit,
					max_snapshot_bytes,
					max_patch_bytes,
				)
			}
			#[cfg(not(target_os = "linux"))]
			{
				let _ = (
					source,
					source_len,
					target,
					target_len,
					rules,
					rule_count,
					omit,
					max_snapshot_bytes,
					max_patch_bytes,
				);
				Err(Status::Unsupported)
			}
		})
	}
}

/// # Safety
/// Borrowed regions and the disjoint writable report satisfy difz-rust.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn difz_directory_apply(
	source: *const u8,
	source_len: usize,
	patch: *const u8,
	patch_len: usize,
	parent: *const u8,
	parent_len: usize,
	output_name: *const u8,
	output_name_len: usize,
	max_snapshot_bytes: u64,
	max_output_bytes: u64,
	out_report: *mut u32,
) -> i32 {
	if out_report.is_null() {
		return Status::Argument as i32;
	}
	guard(|| {
		#[cfg(target_os = "linux")]
		{
			// Input regions stay borrowed only through this guarded call. The
			// report is published after successful no-replace filesystem commit.
			let report = unsafe {
				linux::apply(
					source,
					source_len,
					patch,
					patch_len,
					parent,
					parent_len,
					output_name,
					output_name_len,
					max_snapshot_bytes,
					max_output_bytes,
				)?
			};
			unsafe {
				out_report.write(report);
			}
			Ok(())
		}
		#[cfg(not(target_os = "linux"))]
		{
			let _ = (
				source,
				source_len,
				patch,
				patch_len,
				parent,
				parent_len,
				output_name,
				output_name_len,
				max_snapshot_bytes,
				max_output_bytes,
			);
			Err(Status::Unsupported)
		}
	})
}

#[cfg(target_os = "linux")]
mod linux {
	use super::{Rule, Status};
	use crate::input;
	use difz_core::{
		metadata::Omit,
		path_filter::{Action, Rule as CoreRule},
		tree_patch::ApplyLimits,
	};
	use difz_platform::{
		Directory,
		linux_tree_capture::{Limits, Options},
		linux_tree_patch,
	};
	use std::{ffi::OsStr, os::unix::ffi::OsStrExt, path::Path};
	unsafe fn path<'a>(data: *const u8, length: usize) -> Result<&'a Path, Status> {
		let bytes = unsafe { input(data, length)? };
		if bytes.is_empty() || bytes.contains(&0) {
			return Err(Status::Argument);
		}
		Ok(Path::new(OsStr::from_bytes(bytes)))
	}
	fn limits(maximum: u64) -> Limits {
		Limits {
			bytes: if maximum == 0 {
				Limits::default().bytes
			} else {
				maximum
			},
			..Limits::default()
		}
	}
	pub unsafe fn publish_file(
		parent: *const u8,
		parent_len: usize,
		name: *const u8,
		name_len: usize,
		bytes: *const u8,
		length: usize,
	) -> Result<(), Status> {
		let parent = unsafe { path(parent, parent_len)? };
		let name = unsafe { input(name, name_len)? };
		let bytes = unsafe { input(bytes, length)? };
		if name.is_empty() || name.contains(&0) || name.contains(&b'/') {
			return Err(Status::Argument);
		}
		let parent = Directory::open(parent).map_err(Status::from)?;
		difz_platform::new_file::publish(&parent, name, bytes).map_err(Status::from)
	}
	pub unsafe fn encode(
		source: *const u8,
		source_len: usize,
		target: *const u8,
		target_len: usize,
		rules: *const Rule,
		count: usize,
		omit: u32,
		snapshot_max: u64,
		patch_max: u64,
	) -> Result<Vec<u8>, Status> {
		let omit = Omit::from_bits(omit).map_err(|_| Status::Argument)?;
		if count > 4096 {
			return Err(Status::Limit);
		}
		if count != 0 && rules.is_null() {
			return Err(Status::Argument);
		}
		let records = if count == 0 {
			&[]
		} else {
			// Count is bounded before slicing; caller grants aligned live records.
			unsafe { std::slice::from_raw_parts(rules, count) }
		};
		let mut selected = Vec::new();
		selected
			.try_reserve_exact(count)
			.map_err(|_| Status::OutOfMemory)?;
		for rule in records {
			if rule.pattern_len > 4096 {
				return Err(Status::Limit);
			}
			let action = match rule.action {
				1 => Action::Include,
				2 => Action::Exclude,
				_ => return Err(Status::Argument),
			};
			let bytes = unsafe { input(rule.pattern, rule.pattern_len)? };
			if bytes.is_empty() || bytes.contains(&0) {
				return Err(Status::Argument);
			}
			let pattern = std::str::from_utf8(bytes).map_err(|_| Status::Argument)?;
			selected.push(CoreRule { action, pattern });
		}
		// Validate every borrowed region before touching the filesystem.
		let source = unsafe { path(source, source_len)? };
		let target = unsafe { path(target, target_len)? };
		let source = Directory::open(source).map_err(Status::from)?;
		let target = Directory::open(target).map_err(Status::from)?;
		let patch = linux_tree_patch::create(
			&source,
			&target,
			Options {
				omit,
				rules: &selected,
				limits: limits(snapshot_max),
			},
		)
		.map_err(Status::from)?;
		if patch_max != 0 && patch.len() as u64 > patch_max {
			return Err(Status::Limit);
		}
		Ok(patch)
	}
	pub unsafe fn apply(
		source: *const u8,
		source_len: usize,
		patch: *const u8,
		patch_len: usize,
		parent: *const u8,
		parent_len: usize,
		output: *const u8,
		output_len: usize,
		snapshot_max: u64,
		output_max: u64,
	) -> Result<u32, Status> {
		let source = unsafe { path(source, source_len)? };
		let parent = unsafe { path(parent, parent_len)? };
		let output = unsafe { input(output, output_len)? };
		let patch = unsafe { input(patch, patch_len)? };
		if output.is_empty() || output.contains(&0) || output.contains(&b'/') {
			return Err(Status::Argument);
		}
		let source = Directory::open(source).map_err(Status::from)?;
		let parent = Directory::open(parent).map_err(Status::from)?;
		let apply_limits = ApplyLimits {
			max_output_bytes: if output_max == 0 {
				ApplyLimits::default().max_output_bytes
			} else {
				output_max
			},
			..ApplyLimits::default()
		};
		linux_tree_patch::apply_auto(
			&source,
			patch,
			&parent,
			output,
			limits(snapshot_max),
			apply_limits,
		)
		.map(|report| report.bits())
		.map_err(Status::from)
	}
	impl From<difz_platform::Error> for Status {
		fn from(error: difz_platform::Error) -> Self {
			use difz_platform::Error;
			match error {
				Error::Io(error) => match error.kind() {
					std::io::ErrorKind::OutOfMemory => Self::OutOfMemory,
					std::io::ErrorKind::InvalidData => Self::InvalidData,
					_ => Self::Io,
				},
				Error::InvalidBasename | Error::InvalidAttributeName => Self::Argument,
				Error::WrongKind => Self::InvalidData,
				Error::OutOfMemory => Self::OutOfMemory,
				Error::LimitExceeded => Self::Limit,
				Error::Metadata(error) => error.into(),
				Error::Transport(error) => error.into(),
				Error::Snapshot(error) => error.into(),
				Error::Filter(error) => error.into(),
				Error::Selection(error) => error.into(),
				Error::TreePatch(error) => error.into(),
			}
		}
	}
	impl From<difz_core::directory::SelectionError> for Status {
		fn from(error: difz_core::directory::SelectionError) -> Self {
			use difz_core::directory::SelectionError;
			match error {
				SelectionError::Snapshot(error) => error.into(),
				SelectionError::Filter(error) => error.into(),
				SelectionError::Metadata(error) => error.into(),
				SelectionError::OutOfMemory => Self::OutOfMemory,
			}
		}
	}
	impl From<difz_core::tree_patch::Error> for Status {
		fn from(error: difz_core::tree_patch::Error) -> Self {
			use difz_core::tree_patch::Error;
			match error {
				Error::OutOfMemory => Self::OutOfMemory,
				Error::LimitExceeded => Self::Limit,
				Error::SourceHashMismatch => Self::WrongSource,
				Error::Metadata(error) => error.into(),
				Error::Snapshot(error) => error.into(),
				Error::Filter(error) => error.into(),
				Error::File(error) => error.into(),
				Error::UnexpectedEndOfInput
				| Error::InvalidMagic
				| Error::UnsupportedVersion
				| Error::PatchHashMismatch
				| Error::ReaderTooOld
				| Error::UnsupportedFlags
				| Error::InvalidRule
				| Error::InvalidOperation
				| Error::InvalidPath
				| Error::InvalidPayload
				| Error::OmittedMetadataPresent
				| Error::TrailingData
				| Error::TargetHashMismatch
				| Error::MissingSourceEntry
				| Error::SourceKindMismatch => Self::InvalidData,
			}
		}
	}
	impl From<difz_core::metadata::Error> for Status {
		fn from(error: difz_core::metadata::Error) -> Self {
			use difz_core::metadata::Error;
			match error {
				Error::OutOfMemory => Self::OutOfMemory,
				Error::InvalidOmitMask
				| Error::EmptyFamily
				| Error::UnknownFamily
				| Error::DuplicateFamily
				| Error::InvalidNsec
				| Error::BadMetadata
				| Error::EmptyName
				| Error::InvalidLogicalName
				| Error::ReservedTransportName
				| Error::InvalidRawName
				| Error::InvalidHardlink
				| Error::InvalidAceName
				| Error::DuplicateXattr
				| Error::DuplicateAce
				| Error::EmptyNativeAcl
				| Error::ZeroLengthHole
				| Error::HoleOverflow
				| Error::TruncatedMetadata
				| Error::TrailingMetadata => Self::InvalidData,
			}
		}
	}
	impl From<difz_core::directory::Error> for Status {
		fn from(error: difz_core::directory::Error) -> Self {
			use difz_core::directory::Error;
			match error {
				Error::TooManyEntries | Error::PathTooLong => Self::Limit,
				Error::EmptyPath
				| Error::InvalidUtf8
				| Error::AbsolutePath
				| Error::BackslashSeparator
				| Error::NulByte
				| Error::InvalidComponent
				| Error::DrivePrefix
				| Error::PathsNotSorted
				| Error::DuplicatePath
				| Error::MissingParent
				| Error::ParentNotDirectory
				| Error::InvalidMode
				| Error::InvalidEntryData
				| Error::SymlinkEscapesRoot
				| Error::InvalidHardlinkRelation
				| Error::InvalidSparseExtent => Self::InvalidData,
			}
		}
	}
	impl From<difz_core::path_filter::Error> for Status {
		fn from(error: difz_core::path_filter::Error) -> Self {
			use difz_core::path_filter::Error;
			match error {
				Error::EmptyPattern => Self::Argument,
				Error::OutOfMemory => Self::OutOfMemory,
				Error::Path(error) => error.into(),
			}
		}
	}
	impl From<difz_core::symlink_transport::Error> for Status {
		fn from(error: difz_core::symlink_transport::Error) -> Self {
			use difz_core::symlink_transport::Error;
			match error {
				Error::InvalidTransport => Self::InvalidData,
				Error::TransportTooLarge => Self::Limit,
				Error::OutOfMemory => Self::OutOfMemory,
				Error::Metadata(error) => error.into(),
			}
		}
	}
}
