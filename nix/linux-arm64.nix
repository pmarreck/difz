{ pkgs, buildStamp, zigBuild, zstdBuild, rustProduct }:
let
	# Build on Linux AMD64; execute the actual ARM64 instructions explicitly.
	# No system-wide binfmt registration or foreign builder is required.
	targetPkgs = (import pkgs.path {
		localSystem = pkgs.stdenv.buildPlatform;
		crossSystem = { config = "aarch64-unknown-linux-musl"; isStatic = true; };
	}) // { buildPackages = pkgs; };
	qemu = pkgs.qemu-user;
	runner = [ "${qemu}/bin/qemu-aarch64" ];
	zstdz = zstdBuild targetPkgs;
	sdk = import ../rust/zstdz-sdk.nix { pkgs = targetPkgs; inherit zstdz buildStamp; };
	library = debug: import ../rust/library.nix { pkgs = targetPkgs; inherit sdk buildStamp debug; };
	frontend = debug: lib: import ../rust/cli.nix { pkgs = targetPkgs; library = lib; inherit debug buildStamp runner; };
	rustReleaseLibrary = library false;
	rustDebugLibrary = library true;
	zigRelease = zigBuild { inherit targetPkgs; };
	zigDebug = zigBuild { inherit targetPkgs; optimize = "Debug"; };
	rustRelease = rustProduct "release" (frontend false rustReleaseLibrary) rustReleaseLibrary;
	rustDebug = rustProduct "debug" (frontend true rustDebugLibrary) rustDebugLibrary;
	products = [ zigRelease zigDebug rustRelease rustDebug ];
	wrapped = map (product: pkgs.writeShellScript "difz-linux-arm64" ''
		exec ${pkgs.lib.escapeShellArgs runner} ${product}/bin/difz "$@"
	'') products;
	source = pkgs.lib.fileset.toSource {
		root = ../.;
		fileset = pkgs.lib.fileset.unions [ ../scripts/check-static-linux.bash ../tests/cli/test_cli.bash ../tests/acceptance/cross-apply ];
	};
in {
	packages = {
		linux-arm64-zig-release = zigRelease;
		linux-arm64-zig-debug = zigDebug;
		linux-arm64-rust-release = rustRelease;
		linux-arm64-rust-debug = rustDebug;
	};
	check = pkgs.runCommand "difz-linux-arm64-emulated-check" {
		inherit source;
		nativeBuildInputs = with pkgs; [ bash coreutils diffutils findutils gnugrep binutils ];
		passthru = { inherit products qemu; execution = "qemu-user-aarch64"; };
	} ''
		export HOME="$TMPDIR/home" DIFZ_LANG=en
		mkdir -p "$HOME"
		for binary in ${pkgs.lib.escapeShellArgs (map (p: "${p}/bin/difz") products)}; do
			bash "$source/scripts/check-static-linux.bash" "$binary"
			readelf -h "$binary" | grep -F AArch64 > /dev/null
			OS=macos ARCH=amd64 PF=macos-amd64 VARIANT=conflicting ${pkgs.lib.escapeShellArgs runner} "$binary" --about > "$TMPDIR/about" 2> "$TMPDIR/about-error"
			test "$(wc -l < "$TMPDIR/about")" -eq 1
			grep -F 'PF=linux-arm64 VARIANT=musl' "$TMPDIR/about"
		done
		if ${pkgs.lib.escapeShellArgs runner} ${pkgs.hello}/bin/hello > "$TMPDIR/wrong-arch-out" 2> "$TMPDIR/wrong-arch-error"; then
			printf 'FAIL ARM64 emulator accepted an AMD64 control\n' >&2; exit 1
		fi
		index=0
		for executable in ${pkgs.lib.escapeShellArgs (map toString wrapped)}; do
			index=$((index + 1))
			case "$index" in 1|3) profile=release;; 2|4) profile=debug;; *) exit 1;; esac
			if ! DIFZ="$executable" DIFZ_TEST_PROFILE="$profile" DIFZ_TEST_DIRECTORY_OMIT=timestamps timeout --kill-after=5s 180s bash "$source/tests/cli/test_cli.bash" > "$TMPDIR/cli-log" 2>&1; then
				cat "$TMPDIR/cli-log" >&2; exit 1
			fi
			tail -3 "$TMPDIR/cli-log"
		done
		timeout --kill-after=5s 180s bash "$source/tests/acceptance/cross-apply" ${builtins.elemAt wrapped 0} ${builtins.elemAt wrapped 2}
		timeout --kill-after=5s 180s bash "$source/tests/acceptance/cross-apply" ${builtins.elemAt wrapped 1} ${builtins.elemAt wrapped 3}
		printf 'PASS Linux ARM64 static products and shared acceptance; execution=qemu-user-aarch64\n'
		touch "$out"
	'';
}
