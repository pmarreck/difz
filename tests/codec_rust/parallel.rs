//! QA-only independent Zstandard frames sharing an immutable source prefix.
use super::{checked, decoder, native, native_decode_into, native_encode};

pub fn encode(
	source: &[u8],
	target: &[u8],
	chunk: usize,
	workers: usize,
) -> (Vec<u8>, usize, usize) {
	let chunks: Vec<&[u8]> = if target.is_empty() {
		vec![target]
	} else {
		target.chunks(chunk).collect()
	};
	let count = chunks.len();
	let used = workers.min(count);
	let frames: Vec<Vec<u8>> = if used == 1 {
		chunks
			.iter()
			.map(|bytes| native_encode(source, bytes))
			.collect()
	} else {
		std::thread::scope(|scope| {
			let mut handles = Vec::with_capacity(used);
			for worker in 0..used {
				let group = &chunks[worker * count / used..(worker + 1) * count / used];
				handles.push(scope.spawn(move || {
					group
						.iter()
						.map(|bytes| native_encode(source, bytes))
						.collect::<Vec<_>>()
				}));
			}
			handles
				.into_iter()
				.flat_map(|handle| handle.join().unwrap())
				.collect()
		})
	};
	(frames.concat(), count, used)
}

fn scan(input: &[u8], expected: usize) -> Vec<(&[u8], usize)> {
	let mut frames = Vec::new();
	let mut offset = 0;
	let mut total = 0usize;
	while offset < input.len() {
		let tail = &input[offset..];
		// The immutable slice bounds the complete compressed frame scan.
		let size = checked(unsafe {
			native::ZSTD_findFrameCompressedSize(tail.as_ptr().cast(), tail.len())
		});
		assert!(size > 0 && size <= tail.len());
		let frame = &tail[..size];
		// Independent one-shot encoders always publish a known content size.
		let content_size =
			unsafe { native::ZSTD_getFrameContentSize(frame.as_ptr().cast(), frame.len()) };
		assert_ne!(content_size, native::ZSTD_CONTENTSIZE_ERROR as u64);
		assert_ne!(content_size, native::ZSTD_CONTENTSIZE_UNKNOWN as u64);
		let decoded = usize::try_from(content_size).unwrap();
		total = total.checked_add(decoded).unwrap();
		assert!(total <= expected);
		frames.push((frame, decoded));
		offset += size;
	}
	assert!(!frames.is_empty());
	assert_eq!(total, expected);
	frames
}

fn decode_group(source: &[u8], frames: &[(&[u8], usize)], mut output: &mut [u8]) {
	let context = decoder();
	for (frame, size) in frames {
		let (destination, remaining) = output.split_at_mut(*size);
		// Every frame receives the same full old binary, including later jobs.
		native_decode_into(&context, source, frame, destination);
		output = remaining;
	}
	assert!(output.is_empty());
}

pub fn decode(
	source: &[u8],
	input: &[u8],
	expected: usize,
	workers: usize,
) -> (Vec<u8>, usize, usize) {
	let frames = scan(input, expected);
	let count = frames.len();
	let used = workers.min(count);
	let mut output = vec![0; expected];
	if used == 1 {
		decode_group(source, &frames, &mut output);
	} else {
		std::thread::scope(|scope| {
			let mut remaining = output.as_mut_slice();
			let mut handles = Vec::with_capacity(used);
			for worker in 0..used {
				let group = &frames[worker * count / used..(worker + 1) * count / used];
				let bytes = group.iter().map(|(_, size)| *size).sum();
				let (destination, rest) = remaining.split_at_mut(bytes);
				remaining = rest;
				handles.push(scope.spawn(move || decode_group(source, group, destination)));
			}
			for handle in handles {
				handle.join().unwrap();
			}
		});
	}
	(output, count, used)
}
