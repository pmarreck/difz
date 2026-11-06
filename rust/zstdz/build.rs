use std::{env, fs, path::PathBuf};

fn main() {
	println!("cargo:rerun-if-env-changed=DIFZ_ZSTDZ_ROOT");
	println!("cargo:rerun-if-env-changed=DIFZ_ZSTDZ_BINDINGS");
	let root =
		PathBuf::from(env::var_os("DIFZ_ZSTDZ_ROOT").expect("Nix must provide pinned zstdz"));
	assert!(
		root.join("lib/libzstd.a").is_file(),
		"missing static zstdz archive"
	);
	let bindings = env::var_os("DIFZ_ZSTDZ_BINDINGS").expect("Nix must generate pinned C bindings");
	println!(
		"cargo:rerun-if-changed={}",
		PathBuf::from(&bindings).display()
	);
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
