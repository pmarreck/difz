use super::*;
use crate::{Directory, tests::Fixture};
use std::{
	ffi::CString,
	fs,
	os::{fd::AsRawFd, unix::fs::symlink},
};

fn set(file: &File, name: &[u8], bytes: &[u8]) {
	let name = CString::new(name).unwrap();
	// Only the test-owned file in Nix scratch is modified. Name and byte
	// buffers stay live for the call; values have an explicit byte length.
	let result = unsafe {
		libc::fsetxattr(
			file.as_raw_fd(),
			name.as_ptr(),
			bytes.as_ptr().cast(),
			bytes.len(),
			0,
		)
	};
	assert_eq!(result, 0, "set attribute: {}", io::Error::last_os_error());
}

#[test]
fn native_raw_values_preserve_binary_empty_growth_limits_and_missing_state() {
	let fixture = Fixture::new();
	fs::write(fixture.0.join("data"), b"").unwrap();
	let file = Directory::open(&fixture.0)
		.unwrap()
		.open_regular_file(b"data")
		.unwrap();
	let value: Vec<u8> = (0..=255).cycle().take(600).collect();
	set(&file, b"user.difz-value", &value);
	set(&file, b"user.difz-empty", b"");
	set(&file, b"user.difz-\xff", b"raw name");
	assert_eq!(get(&file, b"user.difz-value", 600).unwrap(), Some(value));
	assert!(matches!(
		get(&file, b"user.difz-value", 599),
		Err(Error::LimitExceeded)
	));
	assert!(matches!(
		get(&file, b"user.difz-value", 0),
		Err(Error::LimitExceeded)
	));
	assert_eq!(get(&file, b"user.difz-empty", 0).unwrap(), Some(vec![]));
	assert_eq!(get(&file, b"user.difz-missing", 0).unwrap(), None);
	assert_eq!(
		get(&file, b"user.difz-\xff", 8).unwrap().unwrap(),
		b"raw name"
	);
	for name in [b"".as_slice(), b"user.a\0tail"] {
		assert!(matches!(
			get(&file, name, 1024),
			Err(Error::InvalidAttributeName)
		));
	}
	assert!(matches!(
		get(&file, &[b'a'; 256], 1024),
		Err(Error::InvalidAttributeName)
	));
}

#[test]
fn native_raw_name_list_matches_independent_kernel_query_and_exact_limits() {
	let fixture = Fixture::new();
	fs::write(fixture.0.join("data"), b"").unwrap();
	let file = File::open(fixture.0.join("data")).unwrap();
	set(&file, b"user.difz-one", b"one");
	set(&file, b"user.difz-two", b"two");
	// Independent size-query strategy on a stable test-owned file.
	let size = unsafe { libc::flistxattr(file.as_raw_fd(), std::ptr::null_mut(), 0) };
	assert!(size > 0);
	let mut expected = vec![0u8; size as usize];
	assert_eq!(
		unsafe {
			libc::flistxattr(
				file.as_raw_fd(),
				expected.as_mut_ptr().cast(),
				expected.len(),
			)
		},
		size
	);
	let count = expected.iter().filter(|byte| **byte == 0).count();
	assert_eq!(list(&file, expected.len(), count).unwrap().0, expected);
	assert!(matches!(
		list(&file, expected.len() - 1, count),
		Err(Error::LimitExceeded)
	));
	assert!(matches!(
		list(&file, expected.len(), count - 1),
		Err(Error::LimitExceeded)
	));
	let names = list(&file, expected.len(), count).unwrap();
	assert!(names.iter().any(|name| name == b"user.difz-one"));
	assert!(names.iter().any(|name| name == b"user.difz-two"));
}

#[test]
fn native_attribute_reads_remain_attached_to_the_opened_file_after_replacement() {
	let fixture = Fixture::new();
	let outside = Fixture::new();
	fs::write(fixture.0.join("data"), b"").unwrap();
	fs::write(outside.0.join("data"), b"").unwrap();
	let file = File::open(fixture.0.join("data")).unwrap();
	let other = File::open(outside.0.join("data")).unwrap();
	set(&file, b"user.difz-value", b"original");
	set(&other, b"user.difz-value", b"outside");
	fs::rename(fixture.0.join("data"), fixture.0.join("moved")).unwrap();
	symlink(outside.0.join("data"), fixture.0.join("data")).unwrap();
	assert_eq!(
		get(&file, b"user.difz-value", 8).unwrap().unwrap(),
		b"original"
	);
	assert_eq!(
		get(&other, b"user.difz-value", 8).unwrap().unwrap(),
		b"outside"
	);
}

#[test]
fn kernel_buffer_and_name_parser_controls_reject_invalid_results() {
	let mut requests = Vec::new();
	let bytes = read_buffer(600, |output| {
		requests.push(output.len());
		if output.len() < 600 {
			return Err(io::Error::from_raw_os_error(libc::ERANGE));
		}
		output[..600].fill(0xff);
		Ok(600)
	})
	.unwrap();
	assert_eq!(requests, [256, 512, 601]);
	assert_eq!(bytes, vec![0xff; 600]);
	assert!(matches!(
		read_buffer(10, |_| Err(io::Error::from_raw_os_error(libc::ERANGE))),
		Err(Error::LimitExceeded)
	));
	assert!(
		matches!(read_buffer(10, |output| Ok(output.len()+1)), Err(Error::Io(error)) if error.kind()==io::ErrorKind::InvalidData)
	);
	assert!(
		matches!(read_buffer(10, |_| Err(io::Error::from_raw_os_error(libc::EIO))), Err(Error::Io(error)) if error.raw_os_error()==Some(libc::EIO))
	);
	assert!(matches!(
		read_buffer(usize::MAX, |_| panic!("must reject before read")),
		Err(Error::LimitExceeded)
	));
	assert!(Names::parse(vec![], 0).unwrap().iter().next().is_none());
	assert_eq!(
		Names::parse(b"a\xff\0".to_vec(), 1)
			.unwrap()
			.iter()
			.next()
			.unwrap(),
		b"a\xff"
	);
	assert_eq!(
		Names::parse(b"a\0b\0".to_vec(), 2)
			.unwrap()
			.iter()
			.collect::<Vec<_>>(),
		[b"a", b"b"]
	);
	assert!(matches!(
		Names::parse(b"a\0b\0".to_vec(), 1),
		Err(Error::LimitExceeded)
	));
	let mut long = vec![b'a'; 256];
	long.push(0);
	assert!(Names::parse(long, 1).is_err());
	for invalid in [b"a".as_slice(), b"\0", b"a\0\0"] {
		assert!(Names::parse(invalid.to_vec(), 10).is_err());
	}
}
