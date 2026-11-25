//! Compile-target identity; runtime environment variables do not select it.
#[derive(Clone, Copy)]
enum Os {
	Linux,
	Macos,
	Mswin,
}
#[derive(Clone, Copy)]
enum Arch {
	Amd64,
	Arm64,
}
const fn platform(os: Os, arch: Arch) -> Option<&'static str> {
	match (os, arch) {
		(Os::Linux, Arch::Amd64) => Some("linux-amd64"),
		(Os::Linux, Arch::Arm64) => Some("linux-arm64"),
		(Os::Macos, Arch::Arm64) => Some("macos-arm64"),
		(Os::Macos, Arch::Amd64) => None,
		(Os::Mswin, Arch::Amd64) => Some("mswin-amd64"),
		(Os::Mswin, Arch::Arm64) => Some("mswin-arm64"),
	}
}
#[cfg(not(any(
	all(
		target_os = "linux",
		any(target_arch = "x86_64", target_arch = "aarch64")
	),
	all(target_os = "macos", target_arch = "aarch64"),
	all(
		target_os = "windows",
		any(target_arch = "x86_64", target_arch = "aarch64")
	),
)))]
compile_error!("difz CLI target is outside the declared five-platform matrix");
const OS: Os = if cfg!(target_os = "linux") {
	Os::Linux
} else if cfg!(target_os = "macos") {
	Os::Macos
} else {
	Os::Mswin
};
const ARCH: Arch = if cfg!(target_arch = "x86_64") {
	Arch::Amd64
} else {
	Arch::Arm64
};
pub const PF: &str = match platform(OS, ARCH) {
	Some(value) => value,
	None => panic!("unsupported compilation target"),
};
pub const OS_LABEL: &str = match OS {
	Os::Linux => "Linux",
	Os::Macos => "macOS",
	Os::Mswin => "Windows",
};
pub const VARIANT: Option<&str> = if cfg!(target_env = "gnu") {
	Some("gnu")
} else if cfg!(target_env = "musl") {
	Some("musl")
} else {
	None
};

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn every_declared_platform_maps_and_the_excluded_pair_is_rejected() {
		for (os, arch, expected) in [
			(Os::Linux, Arch::Amd64, Some("linux-amd64")),
			(Os::Linux, Arch::Arm64, Some("linux-arm64")),
			(Os::Macos, Arch::Amd64, None),
			(Os::Macos, Arch::Arm64, Some("macos-arm64")),
			(Os::Mswin, Arch::Amd64, Some("mswin-amd64")),
			(Os::Mswin, Arch::Arm64, Some("mswin-arm64")),
		] {
			assert_eq!(platform(os, arch), expected);
		}
	}
}
