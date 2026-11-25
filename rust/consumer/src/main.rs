#![forbid(unsafe_code)]

mod measurement;
mod structure_measurement;

fn main() {
	let args: Vec<String> = std::env::args().skip(1).collect();
	if args.first().map(String::as_str) == Some("--structure-declarations") {
		let declarations: Vec<_> = difz_core::growth::Operation::ALL
			.iter()
			.map(
				|op| serde_json::json!({"operation":op.name(),"model":op.model(),"axis":op.axis().name(),"sizes":op.sizes()}),
			)
			.collect();
		println!("{}", serde_json::to_string(&declarations).unwrap());
		return;
	}
	if args.first().map(String::as_str) == Some("--measure-structure") {
		structure_measurement::run(&args[1..]);
		return;
	}
	if args.first().map(String::as_str) == Some("--native-parameters") {
		println!("{}", include_str!(env!("DIFZ_NATIVE_PARAMS")));
		return;
	}
	if args.first().map(String::as_str) == Some("--declarations") {
		let declarations: Vec<_> = difz_core::file::Operation::ALL
			.iter()
			.map(|op| serde_json::json!({"operation":op.name(),"model":op.expected_model()}))
			.collect();
		println!("{}", serde_json::to_string(&declarations).unwrap());
		return;
	}
	if args.first().map(String::as_str) == Some("--measure") {
		measurement::run(&args[1..]);
		return;
	}
	let source = b"binary\0source\xff";
	let target = b"binary\0TARGET\x80\0";
	let patch = difz_core::file::encode(source, target).unwrap();
	assert_eq!(difz_core::file::apply(source, &patch, 0).unwrap(), target);
	assert!(difz_core::file::apply(b"wrong source", &patch, 0).is_err());
	let (mut header, frame) = difz_core::Header::decode_prefix(&patch).unwrap();
	header.target_len = 1 << 30;
	let mut huge = header.encode().to_vec();
	huge.extend(frame);
	let mut wrong = source.to_vec();
	wrong[0] ^= 1;
	assert_eq!(
		difz_core::file::apply(&wrong, &huge, 0),
		Err(difz_core::file::Error::SourceHashMismatch)
	);
	assert_eq!(
		difz_core::file::apply(source, &huge, 1),
		Err(difz_core::file::Error::ResourceLimitExceeded)
	);
	if std::env::args().nth(1).as_deref() == Some("--allocation-proof") {
		prove_shared_hardlinks();
		assert_eq!(
			difz_core::file::apply(source, &huge, 0),
			Err(difz_core::file::Error::OutOfMemory)
		);
		use difz_core::metadata::{CanonicalMetadata, Metadata, Omit, Xattr, XattrClass};
		use std::borrow::Cow;
		// Repeated borrowed values request over 4 GiB of output with 64 MiB of input.
		let value = vec![0u8; 64 << 20];
		let mut attributes: Vec<_> = (0..64)
			.map(|index| Xattr {
				class: XattrClass::Logical,
				name: Cow::Owned(format!("alias-{index:02}").into_bytes()),
				value: Cow::Borrowed(value.as_slice()),
			})
			.collect();
		attributes.reverse();
		let metadata = CanonicalMetadata::normalize(
			Metadata {
				xattrs: attributes,
				..Metadata::default()
			},
			Omit::default(),
		)
		.unwrap();
		assert_eq!(
			metadata.encode(),
			Err(difz_core::metadata::Error::OutOfMemory)
		);
		assert_eq!(
			metadata.into_owned(),
			Err(difz_core::metadata::Error::OutOfMemory)
		);
		println!(
			"PASS canonical metadata encoding and ownership allocation failures are recoverable"
		);
		assert_eq!(
			CanonicalMetadata::decode(&u32::MAX.to_le_bytes()),
			Err(difz_core::metadata::Error::TruncatedMetadata)
		);
	}
	println!("PASS transitive Cargo consumer: binary prefix round trip and wrong-source rejection");
}

// The Nix check runs this consumer under a 128 MiB address-space ceiling.
// Expanded hardlink bytes exceed that ceiling, while unique live data fits.
// This distinguishes sharing during reconstruction from copying first and
// deduplicating afterward, which a final pointer-equality check cannot detect.
fn prove_shared_hardlinks() {
	use difz_core::{
		directory::{CanonicalSnapshot, Content, Entry, Mode, Snapshot},
		metadata::{CanonicalMetadata, Metadata},
		tree_patch::{self, ApplyLimits, CreateOptions},
	};
	use std::borrow::Cow;
	const LENGTH: usize = 4 << 20;
	const ALIASES: usize = 96;
	let source_bytes = vec![0u8; LENGTH];
	let mut target_bytes = vec![0u8; LENGTH];
	target_bytes[LENGTH / 2] = 0xff;
	let mode = Mode::from_bits(0o644).unwrap();
	let source = CanonicalSnapshot::new(Snapshot {
		entries: vec![Entry {
			path: Cow::Borrowed(b"base"),
			content: Content::File {
				mode,
				bytes: Cow::Borrowed(&source_bytes),
			},
			metadata: CanonicalMetadata::default(),
		}],
		root: CanonicalMetadata::default(),
	})
	.unwrap();
	let mut entries = vec![Entry {
		path: Cow::Borrowed(b"base"),
		content: Content::File {
			mode,
			bytes: Cow::Borrowed(&target_bytes),
		},
		metadata: CanonicalMetadata::default(),
	}];
	for index in 0..ALIASES {
		entries.push(Entry {
			path: Cow::Owned(format!("link-{index:03}").into_bytes()),
			content: Content::File {
				mode,
				bytes: Cow::Borrowed(&target_bytes),
			},
			metadata: CanonicalMetadata::new(Metadata {
				hardlink_to: Some(Cow::Borrowed(b"base")),
				..Metadata::default()
			})
			.unwrap(),
		});
	}
	let target = CanonicalSnapshot::new(Snapshot {
		entries,
		root: CanonicalMetadata::default(),
	})
	.unwrap();
	let patch = tree_patch::create(&source, &target, CreateOptions::default()).unwrap();
	let maximum = ((ALIASES + 1) * LENGTH) as u64;
	let output = tree_patch::apply(
		&source,
		&patch,
		ApplyLimits {
			max_output_bytes: maximum,
			..ApplyLimits::default()
		},
	)
	.unwrap();
	assert_eq!(output.hash(), target.hash());
	assert!(matches!(
		output.snapshot().entries[0].content,
		Content::File {
			bytes: Cow::Owned(_),
			..
		}
	));
	let pointer = output.snapshot().entry_bytes(0).unwrap().as_ptr();
	for index in 1..=ALIASES {
		assert!(matches!(
			output.snapshot().entries[index].content,
			Content::FileAlias { target: 0, .. }
		));
		assert_eq!(
			output.snapshot().entry_bytes(index).unwrap().as_ptr(),
			pointer
		);
	}
	assert_eq!(
		tree_patch::apply(
			&source,
			&patch,
			ApplyLimits {
				max_output_bytes: maximum - 1,
				..ApplyLimits::default()
			}
		),
		Err(tree_patch::Error::LimitExceeded)
	);
	println!(
		"PASS owned delta and 96 hardlinks share one buffer under the address-space ceiling; logical output limits remain enforced"
	);
}
