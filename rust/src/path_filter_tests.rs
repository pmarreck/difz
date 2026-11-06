use super::*;
use crate::metadata::tests::Reference;
use alloc::{
	format,
	string::{String, ToString},
	vec,
	vec::Vec,
};

fn wire(rules: &[Rule<'_>], path: Option<&[u8]>) -> Vec<u8> {
	let mut bytes = (rules.len() as u32).to_le_bytes().to_vec();
	for Rule { action, pattern } in rules {
		bytes.push(match action {
			Action::Include => 1,
			Action::Exclude => 2,
		});
		bytes.extend_from_slice(&(pattern.len() as u32).to_le_bytes());
		bytes.extend_from_slice(pattern.as_bytes());
	}
	if let Some(path) = path {
		bytes.extend_from_slice(path);
	}
	bytes
}
fn error(e: Error) -> String {
	match e {
		Error::Path(e) => format!("{e:?}"),
		Error::EmptyPattern => "EmptyPattern".to_string(),
		Error::OutOfMemory => "OutOfMemory".to_string(),
	}
}
fn compare(reference: &mut Reference, rules: &[Rule<'_>], paths: &[&[u8]]) {
	let compiled = Filter::compile(rules);
	assert_eq!(
		compiled.as_ref().map(|_| vec![]).map_err(|e| error(*e)),
		reference.call(50, &wire(rules, None)),
		"rules={rules:?}"
	);
	if let Ok(compiled) = compiled {
		for path in paths {
			assert_eq!(
				compiled
					.includes(path)
					.map(|included| vec![u8::from(included)])
					.map_err(error),
				reference.call(51, &wire(rules, Some(path))),
				"rules={rules:?} path={path:?}"
			);
		}
	}
}

#[test]
fn ordered_rules_default_selection_negation_and_path_errors_match_native() {
	use Action::*;
	let mut reference = Reference::start();
	let rules = [
		Rule {
			action: Include,
			pattern: "**",
		},
		Rule {
			action: Exclude,
			pattern: "**/*.tmp",
		},
		Rule {
			action: Exclude,
			pattern: "src/**",
		},
		Rule {
			action: Include,
			pattern: "src/main.zig",
		},
		Rule {
			action: Exclude,
			pattern: ".*",
		},
		Rule {
			action: Exclude,
			pattern: "literal\\*name",
		},
	];
	let cases: &[(&[u8], bool)] = &[
		(b"README.md", true),
		(b".env", false),
		(b"src/main.zig", true),
		(b"src/generated/cache.zig", false),
		("docs/δ.md".as_bytes(), true),
		(b"nested/cache.tmp", false),
		(b"literal*name", false),
		(b"literalXname", true),
	];
	let filter = Filter::compile(&rules).unwrap();
	for (path, expected) in cases {
		assert_eq!(filter.includes(path).unwrap(), *expected);
	}
	let paths: &[&[u8]] = &[
		b"",
		b"a",
		b"keep.log",
		b"drop.log",
		b"secret.log",
		b"x/y",
		b"/x",
		b"a//b",
		b"a/../b",
		b"c:x",
		b"x\\y",
		b"\0",
		b"\xff",
	];
	compare(&mut reference, &rules, paths);
	compare(&mut reference, &[], paths);
	compare(
		&mut reference,
		&[
			Rule {
				action: Exclude,
				pattern: "*.log",
			},
			Rule {
				action: Exclude,
				pattern: "!keep.log",
			},
			Rule {
				action: Include,
				pattern: "!secret.log",
			},
		],
		paths,
	);
	for pattern in ["", "!", "!!", "\\!", "!**", "!*", "!a", "!\\*"] {
		for action in [Include, Exclude] {
			compare(&mut reference, &[Rule { action, pattern }], paths);
		}
	}
	let long = "a".repeat(directory::MAX_PATH_BYTES + 1);
	compare(&mut reference, &[], &[long.as_bytes()]);
}

#[test]
fn wildcard_classes_unicode_escaping_and_newline_semantics_match_native() {
	let mut reference = Reference::start();
	let patterns = [
		"*",
		"**",
		"***",
		"****",
		"**/",
		"**/*",
		"**/**",
		"a**b",
		"a/**/b",
		"a*b",
		"?",
		"??",
		"[a-z]",
		"[!a]",
		"[^a]",
		"[]]",
		"[!]]",
		"[a\\]]",
		"[a\\-z]",
		"[[]",
		"[[a]",
		"[",
		"[]",
		"[!",
		"[!]",
		"[[[",
		"[\\]",
		"[\\[]",
		"[a^]",
		"[&&]",
		"[a&&b]",
		"\\*",
		"a\\?",
		"\\",
		"a\\",
		"[δ😀]",
		"[!δ]",
		"δ?",
		"?😀",
		"\\δ",
		"[\\δ]",
		"x**/y",
		"**/y",
		"a\nb",
		"[\n]",
		"**[\n]**",
		"[\r\n]",
		"[\u{2028}]",
		"[a\0b]",
	];
	let paths: &[&[u8]] = &[
		b"a",
		b"b",
		b"z",
		b"-",
		b"[",
		b"]",
		b"^",
		b"&",
		b"*",
		b"?",
		b"aa",
		b"ab",
		b"az",
		b"a?",
		b"a/b",
		b"a/x/b",
		b"x/y",
		b"x/dir/y",
		b"y",
		b"a\nb",
		b"a\n",
		b"a\r",
		b"\n",
		b"\r",
		b"x/\ny",
		b"x\n/y",
		b"a/\n/b",
		"δ".as_bytes(),
		"😀".as_bytes(),
		"δ😀".as_bytes(),
		"δa".as_bytes(),
		"a😀".as_bytes(),
		"\u{85}".as_bytes(),
		"\u{2028}".as_bytes(),
		"\u{2029}".as_bytes(),
	];
	for pattern in patterns {
		compare(
			&mut reference,
			&[Rule {
				action: Action::Include,
				pattern,
			}],
			paths,
		);
	}
	for byte in 1..=255u8 {
		compare(
			&mut reference,
			&[Rule {
				action: Action::Include,
				pattern: "?",
			}],
			&[&[byte]],
		);
	}
}

#[test]
fn short_glob_syntax_and_adversarial_patterns_match_native_without_backtracking() {
	let mut reference = Reference::start();
	let alphabet = ['a', '*', '?', '[', ']', '!', '^', '\\', '-', '/'];
	let paths: &[&[u8]] = &[
		b"a", b"aa", b"ab", b"a/b", b"a/x/b", b"[", b"]", b"-", b"^", b"!", b"*", b"a\n", b"\n",
		b"[]", b"[!]", b"[[", b"x/y",
	];
	for length in 1..=3u32 {
		for mut number in 0..alphabet.len().pow(length) {
			let mut pattern = String::new();
			for _ in 0..length {
				pattern.push(alphabet[number % alphabet.len()]);
				number /= alphabet.len();
			}
			compare(
				&mut reference,
				&[Rule {
					action: Action::Include,
					pattern: &pattern,
				}],
				paths,
			);
		}
	}
	for pattern in [
		format!("{}b", "*a".repeat(200)),
		format!("{}b", "**/".repeat(200)),
		"[".repeat(4096),
	] {
		let path = format!("{}c", "a".repeat(1000));
		compare(
			&mut reference,
			&[Rule {
				action: Action::Include,
				pattern: &pattern,
			}],
			&[path.as_bytes()],
		);
	}
}
