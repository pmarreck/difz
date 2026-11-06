//! Ordered path globs, compiled to a bounded dynamic program without FFI.
use crate::directory;
use alloc::vec::Vec;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Action {
	Include,
	Exclude,
}
impl Action {
	fn opposite(self) -> Self {
		match self {
			Self::Include => Self::Exclude,
			Self::Exclude => Self::Include,
		}
	}
}
#[derive(Clone, Copy, Debug)]
pub struct Rule<'a> {
	pub action: Action,
	pub pattern: &'a str,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
	EmptyPattern,
	OutOfMemory,
	Path(directory::Error),
}

enum Token {
	Literal(char),
	Any,
	Star { cross_directories: bool },
	TreePrefix,
	Class { negated: bool, members: Vec<char> },
}
struct CompiledRule {
	action: Action,
	tokens: Vec<Token>,
}
pub struct Filter {
	rules: Vec<CompiledRule>,
	default_included: bool,
}

fn push<T>(values: &mut Vec<T>, value: T) -> Result<(), Error> {
	values.try_reserve(1).map_err(|_| Error::OutOfMemory)?;
	values.push(value);
	Ok(())
}
fn characters(text: &str) -> Result<Vec<char>, Error> {
	let mut chars = Vec::new();
	chars
		.try_reserve_exact(text.len())
		.map_err(|_| Error::OutOfMemory)?;
	chars.extend(text.chars());
	Ok(chars)
}
fn compile(pattern: &str) -> Result<Vec<Token>, Error> {
	let chars = characters(pattern)?;
	let mut tokens = Vec::new();
	tokens
		.try_reserve_exact(chars.len())
		.map_err(|_| Error::OutOfMemory)?;
	let mut i = 0;
	let mut classes_remain = true;
	while i < chars.len() {
		let token = match chars[i] {
			'\\' => {
				i += usize::from(i + 1 < chars.len());
				Token::Literal(chars[i])
			}
			'*' if chars.get(i + 1) == Some(&'*') => {
				i += 1;
				if chars.get(i + 1) == Some(&'/') {
					i += 1;
					Token::TreePrefix
				} else {
					Token::Star {
						cross_directories: true,
					}
				}
			}
			'*' => Token::Star {
				cross_directories: false,
			},
			'?' => Token::Any,
			'[' if classes_remain => {
				let mut j = i + 1;
				let negated = matches!(chars.get(j), Some('!' | '^'));
				j += usize::from(negated);
				let mut members = Vec::new();
				if chars.get(j) == Some(&']') {
					push(&mut members, ']')?;
					j += 1;
				}
				while j < chars.len() && chars[j] != ']' {
					if chars[j] == '\\' && j + 1 < chars.len() {
						j += 1;
					}
					push(&mut members, chars[j])?;
					j += 1;
				}
				if j < chars.len() {
					i = j;
					Token::Class { negated, members }
				} else {
					// No unescaped closing bracket remains in this suffix. Later
					// opening brackets cannot start a valid class either; avoid
					// rescanning the suffix for every unmatched opening bracket.
					classes_remain = false;
					Token::Literal('[')
				}
			}
			literal => Token::Literal(literal),
		};
		tokens.push(token);
		i += 1;
	}
	Ok(tokens)
}
impl Filter {
	/// Compilation takes O(pattern bytes) space and expected work. Patterns
	/// retain literal class hyphens, escaped characters and native globstar rules.
	pub fn compile(rules: &[Rule<'_>]) -> Result<Self, Error> {
		let mut compiled = Vec::new();
		compiled
			.try_reserve_exact(rules.len())
			.map_err(|_| Error::OutOfMemory)?;
		let mut default_included = true;
		for Rule { action, pattern } in rules {
			if *action == Action::Include {
				default_included = false;
			}
			let (action, pattern) = match pattern.strip_prefix('!') {
				Some(pattern) => (action.opposite(), pattern),
				None => (*action, *pattern),
			};
			if pattern.is_empty() {
				return Err(Error::EmptyPattern);
			}
			compiled.push(CompiledRule {
				action,
				tokens: compile(pattern)?,
			});
		}
		Ok(Self {
			rules: compiled,
			default_included,
		})
	}
	/// Work is O(total pattern bytes * path characters), auxiliary space O(path
	/// bytes). All matches cover the complete path; rule order is significant.
	/// Two dynamic-program rows avoid recursive or exponential backtracking.
	pub fn includes(&self, path: &[u8]) -> Result<bool, Error> {
		directory::validate_path(path).map_err(Error::Path)?;
		if self.rules.is_empty() {
			return Ok(self.default_included);
		}
		let path =
			core::str::from_utf8(path).map_err(|_| Error::Path(directory::Error::InvalidUtf8))?;
		let chars = characters(path)?;
		let mut next = Vec::new();
		let mut current = Vec::new();
		for row in [&mut next, &mut current] {
			row.try_reserve_exact(chars.len() + 1)
				.map_err(|_| Error::OutOfMemory)?;
			row.resize(chars.len() + 1, false);
		}
		let mut included = self.default_included;
		for CompiledRule { action, tokens } in &self.rules {
			next.fill(false);
			next[chars.len()] = true;
			for token in tokens.iter().rev() {
				let mut directory_prefix = false;
				for j in (0..=chars.len()).rev() {
					let ch = chars.get(j).copied();
					current[j] = match token {
						Token::Literal(expected) => ch == Some(*expected) && next[j + 1],
						Token::Any => ch.is_some_and(|c| c != '/') && next[j + 1],
						Token::Class { negated, members } => {
							ch.is_some_and(|c| members.contains(&c) != *negated) && next[j + 1]
						}
						Token::Star { cross_directories } => {
							next[j]
								|| ch.is_some_and(|c| {
									c != if *cross_directories { '\n' } else { '/' }
								}) && current[j + 1]
						}
						Token::TreePrefix => {
							match ch {
								None | Some('\n') => directory_prefix = false,
								Some('/') if next[j + 1] => directory_prefix = true,
								Some(_) => {}
							}
							next[j] || directory_prefix
						}
					};
				}
				core::mem::swap(&mut next, &mut current);
			}
			if next[0] {
				included = *action == Action::Include;
			}
		}
		Ok(included)
	}
}

#[cfg(test)]
#[path = "path_filter_tests.rs"]
mod tests;
