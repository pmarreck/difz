use crate::Error;

/// Strict, fallible UTF-16LE to UTF-8, including an optional trusted prefix.
pub(super) fn decode(
	bytes: &[u8],
	maximum: usize,
	prefix: &str,
	invalid: fn() -> Error,
) -> Result<Vec<u8>, Error> {
	if bytes.len() % 2 != 0 {
		return Err(invalid());
	}
	if prefix.len() > maximum {
		return Err(Error::LimitExceeded);
	}
	let upper = (bytes.len() / 2)
		.checked_mul(3)
		.and_then(|n| n.checked_add(prefix.len()))
		.ok_or(Error::LimitExceeded)?
		.min(maximum);
	let mut output = Vec::new();
	output
		.try_reserve_exact(upper)
		.map_err(|_| Error::OutOfMemory)?;
	output.extend_from_slice(prefix.as_bytes());
	let units = bytes
		.chunks_exact(2)
		.map(|pair| u16::from_le_bytes([pair[0], pair[1]]));
	for character in char::decode_utf16(units) {
		let character = character.map_err(|_| invalid())?;
		if character == '\0' {
			return Err(invalid());
		}
		let mut encoded = [0; 4];
		let encoded = character.encode_utf8(&mut encoded).as_bytes();
		if encoded.len() > maximum - output.len() {
			return Err(Error::LimitExceeded);
		}
		output.extend_from_slice(encoded);
	}
	Ok(output)
}
