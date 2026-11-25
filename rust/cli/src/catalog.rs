//! Prepare-phase typed catalogs. Missing translations are explicit at startup.
macro_rules! catalog {
	($($field:ident: $value:expr),+ $(,)?) => {
		pub struct Catalog { $(pub $field: &'static str),+ }
		pub const EN: Catalog = Catalog { $($field: $value),+ };
		#[cfg(test)] fn english_values() -> &'static [&'static str] { &[$(EN.$field),+] }
	};
}
catalog! {
	help: "Usage: difz [options] <file_or_dir_a> <file_or_dir_b>\n       difz --patch [options] <file_or_dir_a> <diff_file>\n       difz --inspect [options] <diff_file>\n\nModes:\n  (default)     Compute a binary diff\n  --patch       Apply a diff\n  --inspect     Describe sizes, hashes, and the zstd frame\n\nOptions:\n  -h, --help         Show help\n  --about            Show version and compilation target\n  -o <path>          Output path (default: stdout)\n  --allow <glob>     Include directory paths (repeatable, ordered)\n  --deny <glob>      Exclude directory paths (repeatable, ordered)\n  --omit-metadata <list>  Omit xattr,acl,timestamps,finder,sparse,hardlink\n  --no-progress      Suppress progress and stats\n  --no-ansi, --no-color  Suppress ANSI escapes\n  --simple           Suppress ANSI and progress\n  --lang <code>      UI language (DIFZ_LANG, then LANG; --lang wins)\n  --hilfe            German help alias\n  --max-output-bytes <n>  Limit patch or reconstruction bytes\n  --max-output-ratio <p>  Limit patch to p percent of target\n  --max-rss-bytes <n>     Process address-space ceiling\n  --max-wall-ms <n>       Process wall-clock ceiling\n\nSpecial paths:\n  - or @stdin   Read stdin\n  - or @stdout  Write stdout\n  @stderr       Write stderr\n",
	description: "fast binary differ (zstd level 9 patch-from)",
	debug: "DEBUG BUILD",
	missing_locale: "WARN: i18n missing-locale",
	unknown_option: "unknown option",
	requires_argument: "requires an argument",
	too_many_arguments: "too many arguments",
	expected_two: "expected 2 file arguments",
	inspect_one: "--inspect requires exactly one diff file argument",
	mutually_exclusive: "--patch and --inspect are mutually exclusive",
	omit_create_only: "--omit-metadata is stored when a directory patch is created",
	omit_directory_only: "--omit-metadata requires directory inputs",
	omit_invalid: "--omit-metadata contains an unknown, empty, or duplicate family",
	too_many_rules: "too many path rules (maximum 4096)",
	rules_directory_only: "--allow and --deny require directory inputs",
	rules_create_only: "--allow and --deny are stored when a directory patch is created",
	need_directory_output: "directory patch requires -o with a new directory path",
	input_kind: "inputs must both be files or both be directories",
	special_input: "unsupported special input file",
	cannot_open: "cannot open",
	read_error: "read error",
	write_error: "write error",
	out_of_memory: "out of memory",
	resource_limit: "resource limit exceeded",
	patch_failed: "patch failed",
	diff_failed: "diff failed",
	inspect_failed: "inspect failed (invalid diff file?)",
	directory_diff_failed: "directory diff failed",
	directory_patch_failed: "directory patch failed",
	source_mismatch: "directory patch source identity does not match",
	unsupported: "operation is unsupported on this target",
	invalid_number: "requires a positive integer",
	bad_ratio: "--max-output-ratio requires an integer 1-100",
	rss_unsupported: "cannot apply --max-rss-bytes ceiling",
	wall_unsupported: "cannot apply --max-wall-ms ceiling",
	wall_exceeded: "difz: wall-clock limit exceeded\n",
	creation_label: "Creating patch",
	application_label: "Applying patch",
	done: "Done",
	frame_report: "difz inspect: zstd level 9 patch-from",
	source_hash: "source blake3",
	target_hash: "target blake3",
	warning_native_acl: "warning: native ACL metadata was preserved in difz.native-acl",
	warning_portable_acl: "warning: portable ACL metadata was preserved in difz.portable-acl",
	warning_finder_flags: "warning: BSD flags were preserved in difz.bsd-flags",
	warning_finder_info: "warning: Finder information was preserved in difz.finder-info",
	warning_birth_time: "warning: birth-time metadata was preserved in difz.btime",
	warning_sparse: "warning: sparse layout was preserved in difz.sparse-holes",
	warning_hardlink: "warning: hardlinks were restored as copies with difz.hardlink-to metadata",
	warning_raw_xattr: "warning: raw attributes were preserved in difz.raw-xattrs",
	warning_symlink: "warning: symlink metadata was preserved in difz.symlinks on the parent directory",
	warning_mtime: "warning: modification-time metadata was preserved in difz.mtime",
}
pub const LOCALES: [&str; 50] = [
	"am", "ar", "az", "bg", "bn", "bs", "da", "de", "el", "en", "es", "fa", "fi", "fil", "fr",
	"ha", "he", "hi", "hr", "hu", "id", "ig", "is", "it", "ja", "km", "ko", "mk", "nb", "nl", "pa",
	"pl", "ps", "pt_br", "ro", "ru", "sl", "sq", "sr", "sv", "sw", "ta", "th", "tr", "uk", "ur",
	"vi", "yo", "zh_hans", "zh_hant",
];
pub fn load(code: &str) -> Option<&'static Catalog> {
	// Adding a translation requires the complete typed Catalog, without defaults.
	const AVAILABLE: &[(&str, &Catalog)] = &[("en", &EN)];
	AVAILABLE
		.iter()
		.find_map(|(name, value)| (*name == code).then_some(*value))
}
pub fn normalize(text: &str) -> Option<&'static str> {
	let normalized = text
		.split(['.', '@'])
		.next()?
		.replace('-', "_")
		.to_ascii_lowercase();
	if matches!(normalized.as_str(), "c" | "posix") {
		return Some("en");
	}
	if normalized == "pt" {
		return Some("pt_br");
	}
	let known = LOCALES
		.iter()
		.copied()
		.filter(|code| {
			normalized == *code
				|| normalized
					.strip_prefix(code)
					.is_some_and(|rest| rest.starts_with('_'))
		})
		.max_by_key(|code| code.len());
	if known.is_some() {
		return known;
	}
	if normalized == "zh" || normalized.starts_with("zh_") {
		return Some(
			if ["zh_tw", "zh_hk", "zh_mo"].iter().any(|code| {
				normalized == *code
					|| normalized
						.strip_prefix(code)
						.is_some_and(|tail| tail.starts_with('_'))
			}) {
				"zh_hant"
			} else {
				"zh_hans"
			},
		);
	}
	None
}
pub fn select(
	args: &[std::ffi::OsString],
	explicit_env: Option<&std::ffi::OsStr>,
	lang: Option<&std::ffi::OsStr>,
) -> String {
	let mut requested = None;
	let mut german_help = false;
	let mut index = 0;
	while index < args.len() {
		match crate::args::ValueFlag::parse(&args[index]) {
			Some(crate::args::ValueFlag::Lang) => {
				requested = args.get(index + 1).map(|value| value.as_os_str());
				index += 2;
			}
			Some(_) => index += 2,
			None => {
				german_help |= args[index] == "--hilfe";
				index += 1;
			}
		}
	}
	let raw = requested
		.or_else(|| german_help.then_some(std::ffi::OsStr::new("de")))
		.or(explicit_env.filter(|value| !value.is_empty()))
		.or(lang.filter(|value| !value.is_empty()));
	let text = raw.map(std::ffi::OsStr::to_string_lossy);
	text.as_deref()
		.and_then(normalize)
		.unwrap_or_else(|| text.as_deref().unwrap_or("en"))
		.to_owned()
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn english_is_complete_and_49_translations_are_explicitly_missing() {
		for value in english_values() {
			assert!(!value.is_empty());
		}
		for code in LOCALES {
			assert_eq!(load(code).is_some(), code == "en");
			assert_eq!(normalize(&code.to_uppercase()), Some(code));
		}
	}
	#[test]
	fn locale_boundaries_scripts_regions_and_precedence_are_explicit() {
		for (input, expected) in [
			("fil_PH.UTF-8", "fil"),
			("fi_FI", "fi"),
			("zh-Hant-HK", "zh_hant"),
			("zh_CN", "zh_hans"),
			("zh_TW", "zh_hant"),
			("zh_MO", "zh_hant"),
			("zh", "zh_hans"),
			("pt-BR", "pt_br"),
			("C.UTF-8", "en"),
		] {
			assert_eq!(normalize(input), Some(expected));
		}
		assert_eq!(normalize("filler"), None);
		let args = ["--hilfe", "--lang", "en"].map(Into::into);
		assert_eq!(
			select(&args, Some("de".as_ref()), Some("fr".as_ref())),
			"en"
		);
		assert_eq!(select(&[], Some("de".as_ref()), Some("fr".as_ref())), "de");
		assert_eq!(select(&[], None, Some("fr_FR.UTF-8".as_ref())), "fr");
		let args = ["--allow", "--lang", "--about"].map(Into::into);
		assert_eq!(select(&args, None, None), "en");
		let args = ["-o", "--hilfe", "a", "b"].map(Into::into);
		assert_eq!(select(&args, None, None), "en");
	}
}
