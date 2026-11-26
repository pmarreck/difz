{ pkgs, buildStamp, zstdBuild, rustProduct, oracles, wrongArchControl }:
let
	targetPkgs = pkgs.pkgsCross.mingwW64 // { buildPackages = pkgs; };
	wine = pkgs.wine64Packages.minimal;
	zstdz = zstdBuild targetPkgs;
	sdk = import ../rust/zstdz-sdk.nix { pkgs = targetPkgs; inherit zstdz buildStamp; };
	# Capture before printing: Wine's CRLF console output otherwise disappears
	# in some Nix log renderers. The Cargo runner also requires a test receipt.
	runWine = receipt: pkgs.writeShellScript "difz-windows-rust-runner" ''
		set -uo pipefail
		export WINEPREFIX="$TMPDIR/wine-prefix" WINEARCH=win64 WINEDEBUG=-all
		export WINEDLLOVERRIDES='mscoree,mshtml=' DISPLAY= WAYLAND_DISPLAY= DBUS_SESSION_BUS_ADDRESS=
		output=$(mktemp "$TMPDIR/wine-output.XXXXXXXX") || exit 1
		errors=$(mktemp "$TMPDIR/wine-errors.XXXXXXXX") || exit 1
		status=0
		${pkgs.coreutils}/bin/timeout --kill-after=5s 120s ${wine}/bin/wine "$@" > "$output" 2> "$errors" || status=$?
		cat "$output"
		cat "$errors" >&2
		${pkgs.lib.optionalString receipt ''
			if [ "$status" -eq 0 ] && ! grep -F 'test result: ok.' "$output" > /dev/null; then
				printf 'FAIL Windows Rust executable produced no affirmative test receipt\n' >&2; exit 1
			fi
		''}
		${pkgs.coreutils}/bin/timeout --kill-after=5s 30s ${wine}/bin/wineserver -w || exit 1
		exit "$status"
	'';
	library = debug: import ../rust/library.nix { pkgs = targetPkgs; inherit sdk buildStamp debug; };
	releaseLibrary = library false;
	debugLibrary = library true;
	frontend = debug: lib: import ../rust/cli.nix {
		pkgs = targetPkgs; library = lib; inherit debug buildStamp;
		runner = [ (runWine true) ];
	};
	release = rustProduct "release" (frontend false releaseLibrary) releaseLibrary;
	debug = rustProduct "debug" (frontend true debugLibrary) debugLibrary;
	products = [ release debug ];
	abiConsumers = map (lib: import ../rust/c-api-consumer.nix {
		pkgs = targetPkgs; library = lib; oracle = builtins.head oracles;
		runner = [ (runWine false) ];
	}) [ releaseLibrary debugLibrary ];
	fileCheck = import ./windows-emulated.nix { inherit pkgs products oracles wrongArchControl; };
in {
	packages = { windows-amd64-rust-release = release; windows-amd64-rust-debug = debug; };
	check = pkgs.runCommand "difz-windows-rust-amd64-check" {
		nativeBuildInputs = with pkgs; [ coreutils gnugrep gnused binutils ];
		passthru = { inherit products abiConsumers sdk; inherit (fileCheck) source execution; };
	} ''
		test -f ${fileCheck}
		for consumer in ${pkgs.lib.escapeShellArgs (map toString abiConsumers)}; do
			test -x "$consumer/bin/difz-rust-abi-consumer.exe"
			grep -Fx 'PASS packaged C ABI execution and export checks' "$consumer/nix-support/abi-check-passed"
		done
		for binary in ${pkgs.lib.escapeShellArgs (map (p: "${p}/bin/difz.exe") products)}; do
			if LC_ALL=C grep -aF '/nix/store/' "$binary" > /dev/null; then
				printf 'FAIL Windows Rust executable contains a Nix store path\n' >&2; exit 1
			fi
			objdump -p "$binary" | sed -n 's/^[[:space:]]*DLL Name: //p' > imports
			test -s imports
			while IFS= read -r dll; do
				case "$dll" in
					KERNEL32.dll|msvcrt.dll|ntdll.dll|USERENV.dll|WS2_32.dll|api-ms-win-core-synch-l1-2-0.dll|bcryptprimitives.dll) :;;
					*) printf 'FAIL unexpected Windows Rust runtime DLL: %s\n' "$dll" >&2; exit 1;;
				esac
			done < imports
		done
		printf 'PASS Windows Rust optimized/Debug CLI, external C ABI, shared file acceptance and system-only imports\n'
		touch "$out"
	'';
}
