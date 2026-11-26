{ pkgs, library, debug ? false }:
(pkgs.rustPlatform.buildRustPackage {
	pname = "difz-rust-cli";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource { root = ./cli; fileset = ./cli; };
	cargoLock.lockFile = ./cli/Cargo.lock;
	strictDeps = true;
	# A standalone CLI must not retain a Nix-store runtime closure.
	allowedReferences = [];
	nativeBuildInputs = [ pkgs.buildPackages.rust-bindgen pkgs.buildPackages.rustPlatform.bindgenHook ];
	buildInputs = [ library ];
	buildType = if debug then "debug" else "release";
	DIFZ_C_API_ROOT = library;
	preBuild = ''
		export DIFZ_C_API_BINDINGS="$TMPDIR/difz-bindings.rs"
		bindgen ${library}/include/difz-rust.h --use-core --no-layout-tests \
			--formatter none --no-prepend-enum-name \
			--allowlist-function 'difz_.*' --allowlist-type 'difz_.*' --allowlist-var 'DIFZ_.*' \
			-- --target=${pkgs.stdenv.hostPlatform.rust.rustcTarget} > "$DIFZ_C_API_BINDINGS"
	'';
	doCheck = true;
	postFixup = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
		# Nix's shrink pass can leave an empty RUNPATH tag on static PIEs.
		# The executable has no loader libraries; retain no search-path tag.
		${pkgs.buildPackages.patchelf}/bin/patchelf --remove-rpath "$out/bin/difz"
	'';
	postCheck = ''
		# Exercise the actual SDK guard, independently of the main CLI build.
		rustc --edition=2024 --target ${pkgs.stdenv.hostPlatform.rust.rustcTarget} \
			-C linker="$CC" build.rs -o "$TMPDIR/abi-target-guard"
		if TARGET=wrong-target "$TMPDIR/abi-target-guard" > "$TMPDIR/guard-output" 2> "$TMPDIR/guard-error"; then
			printf 'FAIL incorrect packaged C ABI target was accepted\n' >&2; exit 1
		fi
		grep -F 'difz C ABI target mismatch' "$TMPDIR/guard-error"
		mkdir "$TMPDIR/guard-bindings"
		TARGET=${pkgs.stdenv.hostPlatform.rust.rustcTarget} CARGO_CFG_TARGET_OS=${if pkgs.stdenv.hostPlatform.isDarwin then "macos" else if pkgs.stdenv.hostPlatform.isLinux then "linux" else "windows"} OUT_DIR="$TMPDIR/guard-bindings" "$TMPDIR/abi-target-guard" > "$TMPDIR/guard-output"
		cmp "$DIFZ_C_API_BINDINGS" "$TMPDIR/guard-bindings/bindings.rs"
	'';
}).overrideAttrs (old: pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
	# pkgsStatic moves build inputs to propagated inputs. The final executable
	# needs its SDK only while building, never as a runtime package dependency.
	buildInputs = (old.buildInputs or []) ++ (old.propagatedBuildInputs or []);
	propagatedBuildInputs = [];
})
