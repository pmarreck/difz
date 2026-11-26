use std::{env, fs, path::PathBuf};
fn main() {
	println!("cargo:rerun-if-env-changed=DIFZ_C_API_ROOT");
	println!("cargo:rerun-if-env-changed=DIFZ_C_API_BINDINGS");
	let root = PathBuf::from(
		env::var_os("DIFZ_C_API_ROOT").expect("Nix must supply the packaged difz C ABI"),
	);
	let target_file = root.join("nix-support/rust-target");
	println!("cargo:rerun-if-changed={}", target_file.display());
	assert_eq!(
		fs::read_to_string(target_file)
			.expect("missing difz ABI target")
			.trim_end(),
		env::var("TARGET").unwrap(),
		"difz C ABI target mismatch"
	);
	let archive = root.join("lib/libdifz_rust.a");
	let provenance = root.join("nix-support/build-provenance.json");
	println!("cargo:rerun-if-changed={}", provenance.display());
	println!("cargo:rerun-if-env-changed=DIFZ_BUILD_PROVENANCE");
	assert_eq!(
		fs::read_to_string(provenance).expect("missing difz ABI provenance"),
		env::var("DIFZ_BUILD_PROVENANCE").expect("Nix must supply validated provenance"),
		"difz C ABI provenance mismatch"
	);
	println!("cargo:rerun-if-changed={}", archive.display());
	assert!(archive.is_file(), "missing static difz C ABI archive");
	let bindings = PathBuf::from(
		env::var_os("DIFZ_C_API_BINDINGS")
			.expect("Nix must generate bindings from the packaged public header"),
	);
	println!("cargo:rerun-if-changed={}", bindings.display());
	fs::copy(
		bindings,
		PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("bindings.rs"),
	)
	.unwrap();
	println!(
		"cargo:rustc-link-search=native={}",
		root.join("lib").display()
	);
	println!("cargo:rustc-link-lib=static=difz_rust");
	if env::var("CARGO_CFG_TARGET_OS").unwrap() == "linux" {
		for library in ["pthread", "dl", "m", "rt", "util"] {
			println!("cargo:rustc-link-lib={library}");
		}
	}
}
