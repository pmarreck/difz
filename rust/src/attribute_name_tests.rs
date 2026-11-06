use super::*;
use crate::metadata::{TRANSPORT_NAMES, tests::Reference};
use alloc::{vec, vec::Vec};

fn check(reference: &mut Reference, os: Os, class: XattrClass, name: &[u8], capacity: usize) {
	let mut request = vec![os as u8, class as u8];
	request.extend_from_slice(&(capacity as u16).to_le_bytes());
	request.extend_from_slice(name);
	let mut output = [0xa5; 260];
	let actual =
		to_native(os, class, name, &mut output[..capacity]).map(|name| name.to_bytes().to_vec());
	let expected = reference.call(54, &request);
	match (&actual, &expected) {
		(Ok(left), Ok(right)) => {
			assert_eq!(left, right, "{os:?} {class:?} {name:?}");
			assert_eq!(output[left.len()], 0);
			assert!(output[left.len() + 1..].iter().all(|byte| *byte == 0xa5));
		}
		(Err(Error::InvalidName), Err(message)) => {
			assert_eq!(message, "InvalidName");
			assert_eq!(output, [0xa5; 260]);
		}
		_ => panic!(
			"native mapping differs: {os:?} {class:?} {name:?} {capacity}: {actual:?} {expected:?}"
		),
	}
}

#[test]
fn native_name_mapping_matches_pinned_dependency_across_all_os_and_classes() {
	let mut reference = Reference::start();
	let mut names = [
		b"".as_slice(),
		b"a",
		b"user.a",
		b"USER.a",
		b"com.apple.FinderInfo",
		b"Zone.Identifier",
		b"$DATA",
		b" leading",
		b"trailing ",
		b"dot.",
		b"a/b",
		b"a\\b",
		b"a:b",
		b"a\0b",
		b"\xff",
		"é".as_bytes(),
	]
	.into_iter()
	.map(<[u8]>::to_vec)
	.collect::<Vec<_>>();
	for &name in TRANSPORT_NAMES {
		names.push(name.to_vec());
		let mut native = b"user.".to_vec();
		native.extend_from_slice(name);
		names.push(native);
	}
	for length in [1, 126, 127, 128, 254, 255, 256] {
		names.push(vec![b'a'; length]);
	}
	for byte in 0..=255 {
		names.push(vec![b'a', byte, b'z']);
		let mut native = b"user.a".to_vec();
		native.push(byte);
		native.push(b'z');
		names.push(native);
	}
	for os in Os::ALL {
		for class in XattrClass::ALL {
			for name in &names {
				check(&mut reference, *os, *class, name, 257);
				let mut request = vec![*os as u8, *class as u8];
				request.extend_from_slice(name);
				let actual = from_native(*os, *class, name);
				let mut encoded = vec![u8::from(actual.is_some())];
				if let Some(bytes) = actual {
					encoded.extend_from_slice(bytes);
					let begin = name.as_ptr() as usize;
					let end = begin + name.len();
					let pointer = bytes.as_ptr() as usize;
					assert!(pointer >= begin && pointer + bytes.len() <= end);
				}
				assert_eq!(
					encoded,
					reference.call(55, &request).unwrap(),
					"{os:?} {class:?} {name:?}"
				);
			}
		}
	}
}

#[test]
fn native_name_buffer_limits_preserve_output_on_failure_and_inverse_on_success() {
	let mut reference = Reference::start();
	for os in Os::ALL {
		for class in XattrClass::ALL {
			for length in [1, 127, 128, 255] {
				let name = vec![b'a'; length];
				for capacity in [0, 1, length, length + 1, (length + 6).min(260)] {
					check(&mut reference, *os, *class, &name, capacity);
				}
				let mut output = [0u8; 260];
				if let Ok(native) = to_native(*os, *class, &name, &mut output) {
					assert_eq!(
						from_native(*os, *class, native.to_bytes()),
						Some(name.as_slice())
					);
				}
			}
		}
	}
}
