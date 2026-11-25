use crate::measurement::{NativeClock, sample_rows_bounded, seeded_bytes};
#[path = "tree_measurement.rs"]
mod tree;
use difz_core::{
	directory::{CanonicalSnapshot, Content, Entry, Mode, Snapshot},
	growth::{Axis, Operation},
	metadata::{CanonicalMetadata, Metadata, Omit, Xattr, XattrClass},
};
use serde_json::json;
use std::{
	borrow::Cow,
	hint::black_box,
	io::Write,
	process::{Command, Stdio},
};

fn external(program: &str, arguments: &[&str], bytes: &[u8]) -> Vec<u8> {
	let mut child = Command::new(program)
		.args(arguments)
		.stdin(Stdio::piped())
		.stdout(Stdio::piped())
		.stderr(Stdio::piped())
		.spawn()
		.unwrap();
	child.stdin.take().unwrap().write_all(bytes).unwrap();
	let output = child.wait_with_output().unwrap();
	assert!(
		output.status.success(),
		"oracle failed: {:?}",
		output.stderr
	);
	assert!(output.stderr.is_empty());
	output.stdout
}
fn metadata_oracle(mode: &str, bytes: &[u8]) -> Vec<u8> {
	assert!(bytes.len() < 1 << 20);
	external(env!("DIFZ_METADATA_ORACLE"), &[mode], bytes)
}
fn independent_hash(bytes: &[u8]) -> [u8; 32] {
	let output = external(env!("B3SUM"), &["--no-names"], bytes);
	let text = std::str::from_utf8(&output).unwrap().trim();
	assert_eq!(text.len(), 64);
	std::array::from_fn(|index| u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).unwrap())
}

struct Backing {
	size: usize,
	names: Vec<Vec<u8>>,
	order: Vec<usize>,
	value: Vec<u8>,
	target_value: Vec<u8>,
}
impl Backing {
	fn new(operation: Operation, size: usize, seed: &str) -> Self {
		let (count, length) = match operation.axis() {
			Axis::Attributes | Axis::Entries => {
				assert!(size <= 8192);
				(size, 16)
			}
			Axis::ValueBytes | Axis::FileBytes => {
				assert!(size <= 65536);
				(8, size)
			}
		};
		assert!(size > 0);
		let names = (0..count)
			.map(|index| format!("item-{index:08x}").into_bytes())
			.collect();
		let priority = seeded_bytes(seed, count * 8);
		let mut order: Vec<_> = (0..count).collect();
		order.sort_unstable_by_key(|&index| (&priority[index * 8..index * 8 + 8], index));
		let length = if matches!(operation, Operation::TreeCreate | Operation::TreeApply) {
			2048
		} else {
			length
		};
		let value = seeded_bytes(seed, length);
		let target_value = if matches!(operation, Operation::TreeCreate | Operation::TreeApply) {
			let mut target = value.clone();
			target[length / 2] ^= 1;
			target
		} else {
			Vec::new()
		};
		Self {
			size,
			names,
			order,
			value,
			target_value,
		}
	}
	fn metadata(&self) -> Metadata<'_> {
		Metadata {
			xattrs: self
				.order
				.iter()
				.map(|&index| Xattr {
					class: XattrClass::Logical,
					name: Cow::Borrowed(&self.names[index]),
					value: Cow::Borrowed(&self.value),
				})
				.collect(),
			..Metadata::default()
		}
	}
	fn snapshot(&self) -> Snapshot<'_> {
		self.snapshot_with(&self.value)
	}
	fn snapshot_with<'a>(&'a self, value: &'a [u8]) -> Snapshot<'a> {
		Snapshot {
			entries: self
				.names
				.iter()
				.map(|name| Entry {
					path: Cow::Borrowed(name),
					content: Content::File {
						mode: Mode::from_bits(0o644).unwrap(),
						bytes: Cow::Borrowed(value),
					},
					metadata: CanonicalMetadata::default(),
				})
				.collect(),
			root: CanonicalMetadata::default(),
		}
	}
}

enum Fixture<'a> {
	Patch(tree::Prepared<'a>),
	Metadata {
		backing: &'a Backing,
		canonical: CanonicalMetadata<'a>,
		wire: Vec<u8>,
		hash: [u8; 32],
	},
	Directory {
		backing: &'a Backing,
		canonical: CanonicalSnapshot<'a>,
		hash: [u8; 32],
	},
}
enum Output<'a> {
	Bytes(Vec<u8>),
	Hash([u8; 32]),
	Metadata(CanonicalMetadata<'a>),
	Directory(CanonicalSnapshot<'a>),
}
impl<'a> Fixture<'a> {
	fn new(operation: Operation, backing: &'a Backing) -> Self {
		match operation {
			Operation::TreeCreate | Operation::TreeApply => {
				Self::Patch(tree::Prepared::new(backing))
			}
			Operation::MetadataEncode
			| Operation::MetadataDecode
			| Operation::MetadataHash
			| Operation::MetadataNormalize => {
				let canonical =
					CanonicalMetadata::normalize(backing.metadata(), Omit::default()).unwrap();
				let wire = canonical.encode().unwrap();
				assert_eq!(metadata_oracle("14", &wire), wire);
				let hash: [u8; 32] = metadata_oracle("15", &wire).try_into().unwrap();
				Self::Metadata {
					backing,
					canonical,
					wire,
					hash,
				}
			}
			Operation::DirectoryCanonical | Operation::DirectoryHash => {
				let canonical = CanonicalSnapshot::new(backing.snapshot()).unwrap();
				// Independent client serializes the documented tree-identity schema
				// from generated inputs, not from the measured library's output.
				let empty_wire = CanonicalMetadata::default().encode().unwrap();
				let metadata_hash = metadata_oracle("15", &empty_wire);
				assert_eq!(metadata_hash.len(), 32);
				let mut identity = b"DIFZTREE-ID\x02".to_vec();
				identity.extend_from_slice(&(backing.names.len() as u32).to_le_bytes());
				for name in &backing.names {
					identity.push(2);
					identity.extend_from_slice(&0o644u16.to_le_bytes());
					identity.extend_from_slice(&(name.len() as u32).to_le_bytes());
					identity.extend_from_slice(name);
					identity.extend_from_slice(&(backing.value.len() as u64).to_le_bytes());
					identity.extend_from_slice(&backing.value);
					identity.extend_from_slice(&metadata_hash);
				}
				let hash = independent_hash(&identity);
				Self::Directory {
					backing,
					canonical,
					hash,
				}
			}
		}
	}
	fn metadata(&self) -> (&'a Backing, &CanonicalMetadata<'a>, &[u8], [u8; 32]) {
		let Self::Metadata {
			backing,
			canonical,
			wire,
			hash,
		} = self
		else {
			panic!("metadata fixture required")
		};
		(backing, canonical, wire, *hash)
	}
	fn directory(&self) -> (&'a Backing, &CanonicalSnapshot<'a>, [u8; 32]) {
		let Self::Directory {
			backing,
			canonical,
			hash,
		} = self
		else {
			panic!("directory fixture required")
		};
		(backing, canonical, *hash)
	}
	fn execute(&self, operation: Operation) -> Output<'_> {
		match operation {
			Operation::TreeCreate => Output::Bytes(black_box(self.patch()).create()),
			Operation::TreeApply => Output::Directory(black_box(self.patch()).apply()),
			Operation::MetadataEncode => {
				Output::Bytes(black_box(self.metadata().1).encode().unwrap())
			}
			Operation::MetadataDecode => {
				Output::Metadata(CanonicalMetadata::decode(black_box(self.metadata().2)).unwrap())
			}
			Operation::MetadataHash => Output::Hash(black_box(self.metadata().1).hash()),
			Operation::MetadataNormalize => Output::Metadata(
				CanonicalMetadata::normalize(
					black_box(self.metadata().0).metadata(),
					Omit::default(),
				)
				.unwrap(),
			),
			Operation::DirectoryCanonical => Output::Directory(
				CanonicalSnapshot::new(black_box(self.directory().0).snapshot()).unwrap(),
			),
			Operation::DirectoryHash => Output::Hash(black_box(self.directory().1).hash()),
		}
	}
	fn correct(&self, operation: Operation, output: &Output<'_>) -> bool {
		match operation {
			Operation::TreeCreate => {
				matches!(output, Output::Bytes(bytes) if self.patch().correct_patch(bytes))
			}
			Operation::TreeApply => {
				matches!(output, Output::Directory(tree) if self.patch().correct_tree(tree))
			}
			Operation::MetadataEncode => {
				matches!(output, Output::Bytes(bytes) if bytes == self.metadata().2)
			}
			Operation::MetadataDecode | Operation::MetadataNormalize => {
				matches!(output, Output::Metadata(metadata) if metadata.encode().unwrap() == self.metadata().2)
			}
			Operation::MetadataHash => {
				matches!(output, Output::Hash(hash) if *hash == self.metadata().3)
			}
			Operation::DirectoryCanonical => {
				matches!(output, Output::Directory(tree) if tree.hash() == self.directory().2 && tree.snapshot().entries.len() == self.directory().0.names.len())
			}
			Operation::DirectoryHash => {
				matches!(output, Output::Hash(hash) if *hash == self.directory().2)
			}
		}
	}
	fn patch(&self) -> &tree::Prepared<'a> {
		let Self::Patch(prepared) = self else {
			panic!("tree patch fixture required")
		};
		prepared
	}
}

pub fn run(args: &[String]) {
	assert!(!cfg!(debug_assertions), "optimized probe required");
	assert_eq!(
		args.len(),
		3,
		"operation, comma-separated sizes, seed required"
	);
	let operation = *Operation::ALL
		.iter()
		.find(|op| op.name() == args[0])
		.unwrap();
	let sizes: Vec<usize> = args[1]
		.split(',')
		.map(|text| text.parse().unwrap())
		.collect();
	assert!((1..=16).contains(&sizes.len()));
	let backings: Vec<_> = sizes
		.iter()
		.map(|&size| Backing::new(operation, size, &args[2]))
		.collect();
	let fixtures: Vec<_> = backings
		.iter()
		.map(|backing| Fixture::new(operation, backing))
		.collect();
	let sweep = sample_rows_bounded(
		fixtures.len(),
		|index| fixtures[index].execute(operation),
		|index, output| {
			assert!(
				fixtures[index].correct(operation, output),
				"codec oracle mismatch"
			)
		},
		&mut NativeClock,
		65536,
	);
	let order: Vec<Vec<_>> = sweep
		.order
		.chunks(fixtures.len())
		.map(|round| round.iter().map(|&index| sizes[index]).collect())
		.collect();
	let rows: Vec<_> = backings.iter().zip(sweep.rows).map(|(backing, samples)| json!({
		"size":backing.size, "descriptors":backing.names.len(), "value_bytes":backing.value.len(),
		"iterations_per_sample":samples.iterations, "samples":{"wall_ns":samples.wall,"cpu_ns":samples.cpu}
	})).collect();
	println!(
		"{}",
		json!({"schema":"performance-measurement/v1", "correct":true,
			"runtime":"Rust-1.94.1/zstdz", "build_mode":"release", "operation":operation.name(),
			"axis":operation.axis().name(), "seed":args[2], "rows":rows, "sample_order":order,
		"fixture":"seeded-binary-values-fixed-width-keys-v1; metadata keys shuffled; required directory paths sorted",
			"clock":"shared resident interleaved sampler; monotonic wall and process CPU; verification, output destruction, RNG, oracle processes and fixture preparation outside timing",
			"canonicalization_scope":"materialize descriptors borrowing prepared bytes, then canonicalize; no payload copies"
		})
	);
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn every_compiled_structure_workload_checks_correct_and_corrupted_real_outputs() {
		for &operation in Operation::ALL {
			let backing = Backing::new(operation, 16, "41");
			let fixture = Fixture::new(operation, &backing);
			let output = fixture.execute(operation);
			assert!(
				fixture.correct(operation, &output),
				"{} positive",
				operation.name()
			);
			let corrupted = match output {
				Output::Bytes(mut bytes) => {
					bytes[0] ^= 1;
					Output::Bytes(bytes)
				}
				Output::Hash(mut hash) => {
					hash[0] ^= 1;
					Output::Hash(hash)
				}
				Output::Metadata(metadata) => {
					let mut raw = metadata.into_metadata();
					raw.finder_flags ^= 1;
					Output::Metadata(CanonicalMetadata::new(raw).unwrap())
				}
				Output::Directory(tree) => {
					let mut raw = tree.into_snapshot();
					let mut bytes = backing.value.clone();
					bytes[0] ^= 1;
					raw.entries[0].content = Content::File {
						mode: Mode::from_bits(0o644).unwrap(),
						bytes: Cow::Owned(bytes),
					};
					Output::Directory(CanonicalSnapshot::new(raw).unwrap())
				}
			};
			assert!(
				!fixture.correct(operation, &corrupted),
				"{} corrupted",
				operation.name()
			);
			assert!(
				!fixture.correct(operation, &Output::Hash([0; 32])),
				"{} skipped",
				operation.name()
			);
		}
	}
}
