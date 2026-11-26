{ pkgs, library, buildStamp, debug ? false, runner ? [] }:
let
	bindgen = import ./bindgen.nix { inherit pkgs; };
	cross = !(pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform);
	guardTarget = if cross then pkgs.stdenv.buildPlatform.rust.rustcTarget else pkgs.stdenv.hostPlatform.rust.rustcTarget;
	guardLinker = if cross then "${pkgs.buildPackages.stdenv.cc}/bin/cc" else "$CC";
in (pkgs.rustPlatform.buildRustPackage ({
	pname = "difz-rust-cli";
	version = "0.1.0";
	src = pkgs.lib.fileset.toSource { root = ./cli; fileset = ./cli; };
	cargoLock.lockFile = ./cli/Cargo.lock;
	strictDeps = true;
	# A standalone CLI must not retain a Nix-store runtime closure.
	allowedReferences = [];
	nativeBuildInputs = bindgen.nativeBuildInputs;
	nativeCheckInputs = pkgs.lib.optional cross pkgs.buildPackages.stdenv.cc;
	buildInputs = [ library ];
	buildType = if debug then "debug" else "release";
	DIFZ_C_API_ROOT = library;
	DIFZ_BUILD_PROVENANCE = buildStamp.text;
	DIFZ_BUILD_REVISION = buildStamp.revision;
	DIFZ_BUILD_DIRTY = buildStamp.dirty;
	postInstall = buildStamp.install;
	preBuild = ''
		export DIFZ_C_API_BINDINGS="$TMPDIR/difz-bindings.rs"
		${bindgen.command} ${library}/include/difz-rust.h --use-core --no-layout-tests \
			--formatter none --no-prepend-enum-name \
			--allowlist-function 'difz_.*' --allowlist-type 'difz_.*' --allowlist-var 'DIFZ_.*' \
			-- ${bindgen.flags} --target=${pkgs.stdenv.hostPlatform.rust.rustcTarget} > "$DIFZ_C_API_BINDINGS"
	'';
	doCheck = true;
	# stdenv disables the normal check phase for a foreign CPU. Cargo knows
	# the explicit emulator, so execute the same hook during the build instead.
	postBuild = pkgs.lib.optionalString (runner != [] && !(pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform)) ''
		cargoCheckHook
	'';
	postFixup = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
		# Nix's shrink pass can leave an empty RUNPATH tag on static PIEs.
		# Other static targets have no dynamic section to edit.
		dynamic_entries=$(${pkgs.buildPackages.binutils}/bin/readelf -d "$out/bin/difz")
		if printf '%s\n' "$dynamic_entries" | ${pkgs.buildPackages.gnugrep}/bin/grep -Eq '\((RPATH|RUNPATH)\)'; then
			${pkgs.buildPackages.patchelf}/bin/patchelf --remove-rpath "$out/bin/difz"
		fi
	'';
	postCheck = ''
		# Exercise the actual SDK guard, independently of the main CLI build.
		rustc --edition=2024 --target ${guardTarget} \
			-C linker="${guardLinker}" build.rs -o "$TMPDIR/abi-target-guard"
		if TARGET=wrong-target "$TMPDIR/abi-target-guard" > "$TMPDIR/guard-output" 2> "$TMPDIR/guard-error"; then
			printf 'FAIL incorrect packaged C ABI target was accepted\n' >&2; exit 1
		fi
		grep -F 'difz C ABI target mismatch' "$TMPDIR/guard-error"
		mkdir "$TMPDIR/guard-bindings"
		if TARGET=${pkgs.stdenv.hostPlatform.rust.rustcTarget} DIFZ_BUILD_PROVENANCE='{}' "$TMPDIR/abi-target-guard" > "$TMPDIR/guard-output" 2> "$TMPDIR/guard-error"; then
			printf 'FAIL incorrect packaged C ABI provenance was accepted\n' >&2; exit 1
		fi
		grep -F 'difz C ABI provenance mismatch' "$TMPDIR/guard-error"
		TARGET=${pkgs.stdenv.hostPlatform.rust.rustcTarget} CARGO_CFG_TARGET_OS=${if pkgs.stdenv.hostPlatform.isDarwin then "macos" else if pkgs.stdenv.hostPlatform.isLinux then "linux" else "windows"} OUT_DIR="$TMPDIR/guard-bindings" "$TMPDIR/abi-target-guard" > "$TMPDIR/guard-output"
		cmp "$DIFZ_C_API_BINDINGS" "$TMPDIR/guard-bindings/bindings.rs"
	'';
} // pkgs.lib.optionalAttrs (runner != []) {
	"CARGO_TARGET_${pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] pkgs.stdenv.hostPlatform.rust.rustcTarget)}_RUNNER" = pkgs.lib.escapeShellArgs runner;
})).overrideAttrs (old: pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
	# pkgsStatic moves build inputs to propagated inputs. The final executable
	# needs its SDK only while building, never as a runtime package dependency.
	buildInputs = (old.buildInputs or []) ++ (old.propagatedBuildInputs or []);
	propagatedBuildInputs = [];
})
