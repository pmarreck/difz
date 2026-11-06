use std::{env, fs, path::PathBuf};

fn main() {
	println!("cargo:rerun-if-env-changed=DIFZ_ZSTDZ_ROOT");
	let root =
		PathBuf::from(env::var_os("DIFZ_ZSTDZ_ROOT").expect("Nix must provide pinned zstdz"));
	let target_file = root.join("nix-support/rust-target");
	println!("cargo:rerun-if-changed={}", target_file.display());
	let sdk_target = fs::read_to_string(target_file).expect("Nix must provide the SDK target");
	assert_eq!(
		sdk_target.trim_end(),
		env::var("TARGET").unwrap(),
		"zstdz SDK target mismatch"
	);
	let archive = root.join("lib/libzstd.a");
	println!("cargo:rerun-if-changed={}", archive.display());
	assert!(archive.is_file(), "missing static zstdz archive");
	let bindings = root.join("share/difz-zstdz/bindings.rs");
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
	println!("cargo:rustc-link-lib=static=zstd");
}
