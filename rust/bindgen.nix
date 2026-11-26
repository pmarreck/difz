{ pkgs }:
let
	tools = pkgs.buildPackages;
	linux = pkgs.stdenv.hostPlatform.isLinux;
	# The wrapped native bindgen injects its own libc headers. Those headers
	# cannot describe a foreign target, even when --target is supplied.
	program = if linux then tools.rust-bindgen-unwrapped else tools.rust-bindgen;
in {
	nativeBuildInputs = [ program tools.rustPlatform.bindgenHook ];
	command = if linux then "${tools.coreutils}/bin/env -u BINDGEN_EXTRA_CLANG_ARGS ${program}/bin/bindgen"
		else "${program}/bin/bindgen";
	flags = pkgs.lib.optionalString linux
		"-nostdinc -isystem ${pkgs.lib.getDev pkgs.stdenv.cc.libc}/include";
}
