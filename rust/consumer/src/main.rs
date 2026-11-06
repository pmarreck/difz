#![forbid(unsafe_code)]

mod measurement;

fn main() {
	let args: Vec<String> = std::env::args().skip(1).collect();
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
		assert_eq!(
			difz_core::file::apply(source, &huge, 0),
			Err(difz_core::file::Error::OutOfMemory)
		);
		use difz_core::metadata::{CanonicalMetadata, Metadata, Xattr, XattrClass};
		use std::borrow::Cow;
		// Repeated borrowed values request over 4 GiB of output with 64 MiB of input.
		let value = vec![0u8; 64 << 20];
		let attributes = (0..64)
			.map(|index| Xattr {
				class: XattrClass::Logical,
				name: Cow::Owned(format!("alias-{index:02}").into_bytes()),
				value: Cow::Borrowed(value.as_slice()),
			})
			.collect();
		let metadata = CanonicalMetadata::new(Metadata {
			xattrs: attributes,
			..Metadata::default()
		})
		.unwrap();
		assert_eq!(
			metadata.encode(),
			Err(difz_core::metadata::Error::OutOfMemory)
		);
		println!("PASS canonical metadata output allocation failure is recoverable");
	}
	println!("PASS transitive Cargo consumer: binary prefix round trip and wrong-source rejection");
}
