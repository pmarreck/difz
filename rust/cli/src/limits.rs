use crate::catalog::Catalog;

#[cfg(unix)]
pub fn apply(memory: u64, wall_ms: u64, messages: &Catalog) -> Result<(), String> {
	if memory != 0 {
		#[cfg(target_os = "linux")]
		{
			let statm = std::fs::read_to_string("/proc/self/statm")
				.map_err(|error| format!("{}: {error}", messages.rss_unsupported))?;
			let pages = statm
				.split_whitespace()
				.next()
				.and_then(|text| text.parse::<u64>().ok())
				.ok_or_else(|| messages.rss_unsupported.to_owned())?;
			// sysconf has no borrowed memory and returns one scalar page size.
			let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
			if page_size <= 0
				|| pages
					.checked_mul(page_size as u64)
					.is_none_or(|used| used > memory)
			{
				return Err(messages.resource_limit.into());
			}
		}
		#[cfg(not(target_os = "linux"))]
		return Err(messages.rss_unsupported.into());
		#[cfg(target_os = "linux")]
		{
			let bound = libc::rlimit {
				rlim_cur: memory as libc::rlim_t,
				rlim_max: memory as libc::rlim_t,
			};
			// One initialized record sets this process's hard and soft ceilings.
			if unsafe { libc::setrlimit(libc::RLIMIT_AS, &bound) } != 0 {
				return Err(format!(
					"{}: {}",
					messages.rss_unsupported,
					std::io::Error::last_os_error()
				));
			}
		}
	}
	if wall_ms != 0 {
		unsafe extern "C" {
			fn setitimer(
				which: libc::c_int,
				new: *const libc::itimerval,
				old: *mut libc::itimerval,
			) -> libc::c_int;
		}
		let seconds = libc::time_t::try_from(wall_ms / 1000)
			.map_err(|_| messages.wall_unsupported.to_owned())?;
		let timer = libc::itimerval {
			it_interval: libc::timeval {
				tv_sec: 0,
				tv_usec: 0,
			},
			it_value: libc::timeval {
				tv_sec: seconds,
				tv_usec: ((wall_ms % 1000) * 1000) as libc::suseconds_t,
			},
		};
		// Both calls operate on this CLI process. The handler uses only
		// async-signal-safe write/_exit and static English fallback bytes.
		if unsafe { libc::signal(libc::SIGALRM, on_alarm as *const () as libc::sighandler_t) }
			== libc::SIG_ERR
			|| unsafe { setitimer(libc::ITIMER_REAL, &timer, std::ptr::null_mut()) } != 0
		{
			return Err(format!(
				"{}: {}",
				messages.wall_unsupported,
				std::io::Error::last_os_error()
			));
		}
	}
	Ok(())
}
#[cfg(unix)]
unsafe extern "C" fn on_alarm(_: libc::c_int) {
	let bytes = crate::catalog::EN.wall_exceeded.as_bytes();
	// Static initialized bytes; no allocation, lock, Rust IO or unwinding.
	unsafe {
		libc::write(libc::STDERR_FILENO, bytes.as_ptr().cast(), bytes.len());
		libc::_exit(124);
	}
}
#[cfg(not(unix))]
pub fn apply(memory: u64, wall_ms: u64, messages: &Catalog) -> Result<(), String> {
	if memory != 0 {
		return Err(messages.rss_unsupported.into());
	}
	if wall_ms != 0 {
		return Err(messages.wall_unsupported.into());
	}
	Ok(())
}
