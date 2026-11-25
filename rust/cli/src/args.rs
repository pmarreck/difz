use crate::{catalog::Catalog, ffi};
use std::ffi::{OsStr, OsString};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Mode {
	Create,
	Apply,
	Inspect,
}
pub struct Config<'a> {
	pub mode: Mode,
	pub input: Vec<&'a OsStr>,
	pub output: Option<&'a OsStr>,
	pub rules: Vec<ffi::difz_path_rule>,
	pub omit: u32,
	pub progress: bool,
	pub max_output: usize,
	pub ratio: u64,
	pub max_memory: u64,
	pub max_wall: u64,
}
pub enum Parsed<'a> {
	Help,
	About,
	Work(Config<'a>),
}
macro_rules! value_flags {
	($($variant:ident => $flag:literal),+ $(,)?) => {
		#[derive(Clone, Copy, Debug, Eq, PartialEq)]
		pub(crate) enum ValueFlag { $($variant),+ }
		impl ValueFlag {
			pub(crate) fn parse(value: &OsStr) -> Option<Self> { match value.to_str()? { $($flag => Some(Self::$variant),)+ _ => None } }
			fn name(self) -> &'static str { match self { $(Self::$variant => $flag),+ } }
			#[cfg(test)] const ALL: &'static [Self] = &[$(Self::$variant),+];
		}
	};
}
value_flags! { Output => "-o", Lang => "--lang", Omit => "--omit-metadata", Include => "--allow", Exclude => "--deny", MaxOutput => "--max-output-bytes", Ratio => "--max-output-ratio", Memory => "--max-rss-bytes", Wall => "--max-wall-ms" }

fn assign<'a>(
	config: &mut Config<'a>,
	option: ValueFlag,
	value: &'a OsStr,
	messages: &Catalog,
) -> Result<(), String> {
	let flag = option.name();
	match option {
		ValueFlag::Output => config.output = Some(value),
		ValueFlag::Lang => {}
		ValueFlag::Omit => {
			let bytes = value.as_encoded_bytes();
			let mut parsed = 0;
			// The C ABI borrows these explicit bytes only during the call.
			let status =
				unsafe { ffi::difz_metadata_omit_parse(bytes.as_ptr(), bytes.len(), &mut parsed) };
			if status != 0 || parsed == 0 || parsed & config.omit != 0 {
				return Err(messages.omit_invalid.into());
			}
			config.omit |= parsed;
		}
		ValueFlag::Include | ValueFlag::Exclude => {
			if config.rules.len() == 4096 {
				return Err(messages.too_many_rules.into());
			}
			let bytes = value.as_encoded_bytes();
			config
				.rules
				.try_reserve(1)
				.map_err(|_| messages.out_of_memory.to_owned())?;
			config.rules.push(ffi::difz_path_rule {
				action: if option == ValueFlag::Include { 1 } else { 2 },
				pattern: bytes.as_ptr(),
				pattern_len: bytes.len(),
			});
		}
		ValueFlag::MaxOutput => {
			config.max_output = usize::try_from(positive(value, flag, messages)?)
				.map_err(|_| messages.resource_limit.to_owned())?
		}
		ValueFlag::Ratio => {
			config.ratio = positive(value, flag, messages)?;
			if config.ratio > 100 {
				return Err(messages.bad_ratio.into());
			}
		}
		ValueFlag::Memory => config.max_memory = positive(value, flag, messages)?,
		ValueFlag::Wall => config.max_wall = positive(value, flag, messages)?,
	}
	Ok(())
}
fn positive(value: &OsStr, flag: &str, messages: &Catalog) -> Result<u64, String> {
	let bytes = value.as_encoded_bytes();
	let result = bytes.iter().try_fold(0u64, |number, &byte| {
		if !byte.is_ascii_digit() {
			return None;
		}
		number.checked_mul(10)?.checked_add(u64::from(byte - b'0'))
	});
	result
		.filter(|&number| number > 0 && !bytes.is_empty())
		.ok_or_else(|| format!("{flag} {}", messages.invalid_number))
}
pub fn parse<'a>(args: &'a [OsString], messages: &Catalog) -> Result<Parsed<'a>, String> {
	let mut config = Config {
		mode: Mode::Create,
		input: Vec::new(),
		output: None,
		rules: Vec::new(),
		omit: 0,
		progress: true,
		max_output: 0,
		ratio: 0,
		max_memory: 0,
		max_wall: 0,
	};
	let mut apply = false;
	let mut inspect = false;
	let mut index = 0;
	while index < args.len() {
		let arg = args[index].as_os_str();
		if let Some(option) = ValueFlag::parse(arg) {
			let value = args
				.get(index + 1)
				.ok_or_else(|| format!("{} {}", option.name(), messages.requires_argument))?;
			assign(&mut config, option, value, messages)?;
			index += 2;
			continue;
		}
		let flag = arg.to_str();
		match flag {
			Some("-h" | "--help" | "--hilfe") => return Ok(Parsed::Help),
			Some("--about") => return Ok(Parsed::About),
			Some("--patch") => apply = true,
			Some("--inspect") => inspect = true,
			Some("--no-progress" | "--simple") => config.progress = false,
			Some("--no-ansi" | "--no-color") => {}
			_ => {
				if arg.as_encoded_bytes().starts_with(b"-") && arg != "-" {
					return Err(format!(
						"{} '{}'",
						messages.unknown_option,
						arg.to_string_lossy()
					));
				}
				if config.input.len() == 2 {
					return Err(messages.too_many_arguments.into());
				}
				config
					.input
					.try_reserve(1)
					.map_err(|_| messages.out_of_memory.to_owned())?;
				config.input.push(arg);
			}
		}
		index += 1;
	}
	if apply && inspect {
		return Err(messages.mutually_exclusive.into());
	}
	config.mode = if inspect {
		Mode::Inspect
	} else if apply {
		Mode::Apply
	} else {
		Mode::Create
	};
	if config.omit != 0 && config.mode != Mode::Create {
		return Err(messages.omit_create_only.into());
	}
	if config.mode == Mode::Inspect {
		if config.input.len() != 1 {
			return Err(messages.inspect_one.into());
		}
	} else if config.input.len() != 2 {
		return Err(messages.expected_two.into());
	}
	Ok(Parsed::Work(config))
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::catalog::EN;
	#[test]
	fn every_declared_value_flag_requires_its_value() {
		for option in ValueFlag::ALL {
			assert!(parse(&[option.name().into()], &EN).is_err());
		}
	}
	#[test]
	fn positive_numbers_reject_every_sign_overflow_zero_and_nondecimal_suffix() {
		for value in ["", "0", "-1", "+1", "1x", "18446744073709551616", " 1"] {
			assert!(positive(value.as_ref(), "--max-wall-ms", &EN).is_err());
		}
		assert_eq!(
			positive("18446744073709551615".as_ref(), "--max-wall-ms", &EN),
			Ok(u64::MAX)
		);
	}
	#[test]
	fn modes_omissions_and_positional_counts_have_no_ambiguous_success_path() {
		for values in [
			vec!["--patch", "--inspect", "a"],
			vec!["--patch", "--omit-metadata", "acl", "a", "b"],
			vec!["--omit-metadata", "acl", "--omit-metadata", "acl", "a", "b"],
			vec!["a"],
			vec!["a", "b", "c"],
			vec!["--max-output-bytes", "0", "a", "b"],
		] {
			assert!(parse(&values.into_iter().map(Into::into).collect::<Vec<_>>(), &EN).is_err());
		}
		let values = ["a", "b", "--patch"].map(Into::into);
		let Parsed::Work(config) = parse(&values, &EN).unwrap() else {
			panic!()
		};
		assert_eq!(config.mode, Mode::Apply);
	}
}
