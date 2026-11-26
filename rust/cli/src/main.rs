//! Public C ABI consumer. Patch business logic belongs to the packaged library.
#![deny(unsafe_op_in_unsafe_fn)]
mod args;
mod catalog;
mod ffi;
mod io;
mod limits;
mod platform;
use args::{Config, Mode, Parsed};
use catalog::Catalog;
use platform::{OS_LABEL, PF, VARIANT};
use std::{
	ffi::OsString,
	io::IsTerminal,
	ptr::{self, NonNull},
};

const MAX_FILE_BYTES: u64 = 1 << 31;
const MAX_PATCH_BYTES: u64 = 16 << 30;

pub(crate) fn check(status: i32, operation: &str, messages: &Catalog) -> Result<(), String> {
	match status {
		0 => Ok(()),
		ffi::DIFZ_LIMIT => Err(messages.resource_limit.into()),
		ffi::DIFZ_OUT_OF_MEMORY => Err(messages.out_of_memory.into()),
		ffi::DIFZ_UNSUPPORTED => Err(messages.unsupported.into()),
		ffi::DIFZ_WRONG_SOURCE if operation == messages.directory_patch_failed => {
			Err(messages.source_mismatch.into())
		}
		_ => Err(operation.into()),
	}
}
struct Output(NonNull<ffi::difz_buffer>);
impl Output {
	fn produce(
		messages: &Catalog,
		operation: &str,
		call: impl FnOnce(*mut *mut ffi::difz_buffer) -> i32,
	) -> Result<Self, String> {
		let mut owner = ptr::null_mut();
		check(call(&mut owner), operation, messages)?;
		NonNull::new(owner)
			.map(Self)
			.ok_or_else(|| operation.to_owned())
	}
	fn bytes(&self) -> &[u8] {
		// This opaque handle came from a successful producer call. The public
		// contract keeps its immutable bytes live until our one matching free.
		let length = unsafe { ffi::difz_buffer_len(self.0.as_ptr()) };
		if length == 0 {
			return &[];
		}
		unsafe { std::slice::from_raw_parts(ffi::difz_buffer_data(self.0.as_ptr()), length) }
	}
}
impl Drop for Output {
	fn drop(&mut self) {
		unsafe {
			ffi::difz_buffer_free(self.0.as_ptr());
		}
	}
}
fn main() -> std::process::ExitCode {
	let args: Vec<OsString> = std::env::args_os().skip(1).collect();
	let explicit = std::env::var_os("DIFZ_LANG");
	let lang = std::env::var_os("LANG");
	let locale = catalog::select(&args, explicit.as_deref(), lang.as_deref());
	let messages = catalog::load(&locale).unwrap_or_else(|| {
		eprintln!("{} {locale}", catalog::EN.missing_locale);
		&catalog::EN
	});
	if cfg!(debug_assertions) {
		eprintln!("{}", messages.debug);
	}
	match run(&args, messages) {
		Ok(()) => std::process::ExitCode::SUCCESS,
		Err(error) => {
			eprintln!("difz: {error}");
			std::process::ExitCode::FAILURE
		}
	}
}
fn run(arguments: &[OsString], messages: &Catalog) -> Result<(), String> {
	let config = match args::parse(arguments, messages)? {
		Parsed::Help => return io::output(None, messages.help.as_bytes(), false, messages),
		Parsed::About => {
			let variant = VARIANT.map_or(String::new(), |value| format!(" VARIANT={value}"));
			let text = format!(
				"difz {} -- {} -- {OS_LABEL} {}; PF={PF}{variant} BUILD={} DIRTY={}\n",
				env!("CARGO_PKG_VERSION"),
				messages.description,
				std::env::consts::ARCH,
				env!("DIFZ_BUILD_REVISION"),
				env!("DIFZ_BUILD_DIRTY")
			);
			return io::output(None, text.as_bytes(), false, messages);
		}
		Parsed::Work(config) => config,
	};
	limits::apply(config.max_memory, config.max_wall, messages)?;
	if config.mode == Mode::Inspect {
		return inspect(&config, messages);
	}
	let first = io::classify(config.input[0], messages)?;
	if config.mode == Mode::Apply && first == io::Kind::Directory {
		return apply_directory(&config, messages);
	}
	if config.mode == Mode::Create {
		let second = io::classify(config.input[1], messages)?;
		if first == io::Kind::Directory || second == io::Kind::Directory {
			if first != io::Kind::Directory || second != io::Kind::Directory {
				return Err(messages.input_kind.into());
			}
			return create_directory(&config, messages);
		}
		if second == io::Kind::Special {
			return Err(messages.special_input.into());
		}
	}
	if first == io::Kind::Special {
		return Err(messages.special_input.into());
	}
	if !config.rules.is_empty() {
		return Err(messages.rules_directory_only.into());
	}
	if config.omit != 0 {
		return Err(messages.omit_directory_only.into());
	}
	file(&config, messages)
}
fn progress(config: &Config<'_>, messages: &Catalog) {
	if config.progress && std::io::stderr().is_terminal() {
		eprintln!(
			"difz: {}",
			if config.mode == Mode::Apply {
				messages.application_label
			} else {
				messages.creation_label
			}
		);
	}
}
fn file(config: &Config<'_>, messages: &Catalog) -> Result<(), String> {
	let source = io::load(config.input[0], MAX_FILE_BYTES, messages)?;
	let other = io::load(
		config.input[1],
		if config.mode == Mode::Apply {
			MAX_PATCH_BYTES
		} else {
			MAX_FILE_BYTES
		},
		messages,
	)?;
	let maximum = if config.mode == Mode::Create && config.ratio != 0 && !other.is_empty() {
		let ratio = ((other.len() as u128 * u128::from(config.ratio)) / 100).max(1) as usize;
		if config.max_output == 0 {
			ratio
		} else {
			ratio.min(config.max_output)
		}
	} else {
		config.max_output
	};
	progress(config, messages);
	let operation = if config.mode == Mode::Apply {
		messages.patch_failed
	} else {
		messages.diff_failed
	};
	let output = Output::produce(messages, operation, |out| unsafe {
		// Input slices and the caller-owned output slot remain live throughout
		// the synchronous packaged C ABI call. Only the returned owner is retained.
		if config.mode == Mode::Apply {
			ffi::difz_file_apply(
				source.as_ptr(),
				source.len(),
				other.as_ptr(),
				other.len(),
				maximum,
				out,
			)
		} else {
			ffi::difz_file_encode(
				source.as_ptr(),
				source.len(),
				other.as_ptr(),
				other.len(),
				maximum,
				out,
			)
		}
	})?;
	io::output(config.output, output.bytes(), false, messages)?;
	if config.progress && std::io::stderr().is_terminal() {
		eprintln!("difz: {}. {}B", messages.done, output.bytes().len());
	}
	Ok(())
}
fn create_directory(config: &Config<'_>, messages: &Catalog) -> Result<(), String> {
	let source = config.input[0].as_encoded_bytes();
	let target = config.input[1].as_encoded_bytes();
	progress(config, messages);
	let patch = Output::produce(messages, messages.directory_diff_failed, |out| unsafe {
		ffi::difz_directory_encode(
			source.as_ptr(),
			source.len(),
			target.as_ptr(),
			target.len(),
			config.rules.as_ptr(),
			config.rules.len(),
			config.omit,
			0,
			config.max_output as u64,
			out,
		)
	})?;
	io::output(config.output, patch.bytes(), true, messages)
}
fn apply_directory(config: &Config<'_>, messages: &Catalog) -> Result<(), String> {
	if !config.rules.is_empty() {
		return Err(messages.rules_create_only.into());
	}
	if io::stream_output(config.output) {
		return Err(messages.need_directory_output.into());
	}
	let output = config
		.output
		.ok_or_else(|| messages.need_directory_output.to_owned())?;
	let (parent, name) = io::split_output(output, messages)?;
	let patch = io::load(config.input[1], MAX_PATCH_BYTES, messages)?;
	let source = config.input[0].as_encoded_bytes();
	let parent = parent.as_encoded_bytes();
	let name = name.as_encoded_bytes();
	let mut report = 0;
	progress(config, messages);
	let status = unsafe {
		ffi::difz_directory_apply(
			source.as_ptr(),
			source.len(),
			patch.as_ptr(),
			patch.len(),
			parent.as_ptr(),
			parent.len(),
			name.as_ptr(),
			name.len(),
			0,
			config.max_output as u64,
			&mut report,
		)
	};
	check(status, messages.directory_patch_failed, messages)?;
	let warnings = [
		messages.warning_native_acl,
		messages.warning_portable_acl,
		messages.warning_finder_flags,
		messages.warning_finder_info,
		messages.warning_birth_time,
		messages.warning_sparse,
		messages.warning_hardlink,
		messages.warning_raw_xattr,
		messages.warning_symlink,
		messages.warning_mtime,
	];
	for (index, message) in warnings.into_iter().enumerate() {
		if report & (1 << index) != 0 {
			eprintln!("difz: {message}");
		}
	}
	Ok(())
}
fn inspect(config: &Config<'_>, messages: &Catalog) -> Result<(), String> {
	let bytes = io::load(config.input[0], MAX_PATCH_BYTES, messages)?;
	let mut info = std::mem::MaybeUninit::<ffi::difz_file_info>::uninit();
	let status = unsafe { ffi::difz_file_inspect(bytes.as_ptr(), bytes.len(), info.as_mut_ptr()) };
	check(status, messages.inspect_failed, messages)?;
	// Success initializes this exact public C structure. The output slot does
	// not overlap the borrowed patch input and no pointer escapes the call.
	let info = unsafe { info.assume_init() };
	let text = format!(
		"{}, source={}, target={}, frame={}\n{}: {}\n{}: {}\n",
		messages.frame_report,
		size(info.source_len),
		size(info.target_len),
		size(info.frame_len as u64),
		messages.source_hash,
		hex(&info.source_hash),
		messages.target_hash,
		hex(&info.target_hash)
	);
	io::output(config.output, text.as_bytes(), false, messages)
}
fn size(bytes: u64) -> String {
	if bytes < 1024 {
		format!("{bytes}B")
	} else if bytes < 1 << 20 {
		format!("{:.1}KB", bytes as f64 / 1024.0)
	} else if bytes < 1 << 30 {
		format!("{:.1}MB", bytes as f64 / (1 << 20) as f64)
	} else {
		format!("{:.1}GB", bytes as f64 / (1 << 30) as f64)
	}
}
fn hex(bytes: &[u8]) -> String {
	use std::fmt::Write;
	let mut result = String::new();
	for byte in bytes {
		let _ = write!(result, "{byte:02x}");
	}
	result
}
