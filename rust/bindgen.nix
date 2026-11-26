{ pkgs }:
let
	tools = pkgs.buildPackages;
	linux = pkgs.stdenv.hostPlatform.isLinux;
	windows = pkgs.stdenv.hostPlatform.isWindows;
	targetHeaders = linux || windows;
	# The wrapped native bindgen injects its own libc headers. Those headers
	# cannot describe a foreign target, even when --target is supplied.
	program = if targetHeaders then tools.rust-bindgen-unwrapped else tools.rust-bindgen;
in {
	# A wrapped Clang would run a compiler setup hook and replace the build
	# compiler's environment. Resource discovery needs only the unwrapped tool.
	nativeBuildInputs = [ program tools.rustPlatform.bindgenHook ] ++ pkgs.lib.optional windows tools.llvmPackages.clang-unwrapped;
	# Rust's gnullvm target spelling is not a Clang target triple.
	target = pkgs.lib.replaceStrings [ "windows-gnullvm" ] [ "windows-gnu" ] pkgs.stdenv.hostPlatform.rust.rustcTarget;
	command = if targetHeaders then "${tools.coreutils}/bin/env -u BINDGEN_EXTRA_CLANG_ARGS ${program}/bin/bindgen"
		else "${program}/bin/bindgen";
	flags = pkgs.lib.optionalString targetHeaders
		"-nostdinc -isystem ${pkgs.lib.getDev pkgs.stdenv.cc.libc}/include"
		+ pkgs.lib.optionalString windows " -isystem $(${tools.llvmPackages.clang-unwrapped}/bin/clang -print-resource-dir)/include";
}
