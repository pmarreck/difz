#![forbid(unsafe_code)]

fn main() {
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
	}
	println!("PASS transitive Cargo consumer: binary prefix round trip and wrong-source rejection");
}
