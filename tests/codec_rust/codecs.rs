//! Shared codec adapters for QA and optimized in-memory probes.
#![forbid(unsafe_code)]

pub fn rust_frame(source: &[u8], target: &[u8], window_override: Option<u32>) -> Vec<u8> {
	rust_frame_options(
		source,
		target,
		window_override,
		rusty_zstd::AdvancedOptions {
			ldm: rusty_zstd::LdmParams::enabled(),
			..Default::default()
		},
	)
}

pub fn rust_frame_options(
	source: &[u8],
	target: &[u8],
	window_override: Option<u32>,
	options: rusty_zstd::AdvancedOptions,
) -> Vec<u8> {
	let span = source.len().max(target.len()) as u64;
	let window = (64 - span.leading_zeros()).clamp(10, 31);
	let mut parameters = rusty_zstd::compression_params(9, Some(target.len() as u64)).unwrap();
	parameters.window_log = window_override.unwrap_or(window);
	rusty_zstd::compress_with_advanced(target, parameters, false, None, source, false, options)
		.unwrap()
}

pub fn rust_decode(frame: &[u8], source: &[u8], _expected: usize) -> Vec<u8> {
	rusty_zstd::decompress_using_prefix_with(
		frame,
		source,
		rusty_zstd::DecompressOptions {
			window_max: 1 << 31,
			force_ignore_checksum: false,
		},
	)
	.unwrap()
}

pub fn structured_frame(source: &[u8], target: &[u8], window: Option<u32>) -> Vec<u8> {
	structured_frame_owned(source.to_vec(), target, window)
}

pub fn structured_frame_owned(source: Vec<u8>, target: &[u8], window: Option<u32>) -> Vec<u8> {
	use structured_zstd::decoding::Dictionary;
	use structured_zstd::encoding::{
		CompressionLevel, CompressionParameters, EncoderDictionary, FrameCompressor,
	};
	let span = source.len().max(target.len()) as u64;
	let log = (64 - span.leading_zeros()).clamp(10, 30);
	let parameters = CompressionParameters::builder(CompressionLevel::Level(9))
		.window_log(window.unwrap_or(log))
		.enable_long_distance_matching(true)
		.build()
		.unwrap();
	let mut encoder: FrameCompressor = FrameCompressor::new(CompressionLevel::Level(9));
	encoder.set_parameters(&parameters);
	encoder.set_content_checksum(false);
	encoder.set_dictionary_id_flag(false);
	if !source.is_empty() {
		let dictionary = Dictionary::from_raw_content(0, source).unwrap();
		encoder
			.set_encoder_dictionary(EncoderDictionary::from_dictionary(dictionary))
			.unwrap();
	}
	encoder.compress_independent_frame(target)
}

pub fn structured_decode_into(
	frame: &[u8],
	source: &[u8],
	output: &mut [u8],
	window_limit: u64,
) -> Result<usize, structured_zstd::decoding::errors::FrameDecoderError> {
	structured_decode_owned_into(frame, source.to_vec(), output, window_limit)
}

pub fn structured_decode_owned_into(
	frame: &[u8],
	source: Vec<u8>,
	output: &mut [u8],
	window_limit: u64,
) -> Result<usize, structured_zstd::decoding::errors::FrameDecoderError> {
	use structured_zstd::decoding::{ContentChecksum, Dictionary, DictionaryHandle, FrameDecoder};
	let mut decoder = FrameDecoder::new();
	decoder.set_content_checksum(ContentChecksum::Verify);
	decoder.set_max_window_size(window_limit)?;
	if source.is_empty() {
		decoder.decode_all(frame, output)
	} else {
		let dictionary = Dictionary::from_raw_content(0, source)?;
		let handle = DictionaryHandle::from_dictionary(dictionary);
		decoder.decode_all_with_dict_handle(frame, output, &handle)
	}
}

pub fn structured_decode(frame: &[u8], source: &[u8], expected: usize) -> Vec<u8> {
	let mut output = vec![0; expected];
	let written = structured_decode_into(frame, source, &mut output, 1 << 31).unwrap();
	assert_eq!(written, expected);
	output
}

pub fn structured_decode_owned(frame: &[u8], source: Vec<u8>, expected: usize) -> Vec<u8> {
	let mut output = vec![0; expected];
	let written = structured_decode_owned_into(frame, source, &mut output, 1 << 31).unwrap();
	assert_eq!(written, expected);
	output
}
