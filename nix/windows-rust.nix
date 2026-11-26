{ pkgs, buildStamp, zstdBuild, rustProduct, oracles, wrongArchControl, arch ? "amd64" }:
let
	arm = arch == "arm64";
	targetPkgs = if arm then import ./windows-arm64-toolchain.nix { inherit pkgs; }
		else pkgs.pkgsCross.mingwW64 // { buildPackages = pkgs; };
	wine = if arm then (import pkgs.path { system = "aarch64-linux"; }).wine64Packages.minimal
		else pkgs.wine64Packages.minimal;
	runnerSource = pkgs.lib.fileset.toSource { root = ../.; fileset = ../scripts/run-arm64-test.bash; };
	invokeWine = pkgs.writeShellScript "difz-windows-${arch}-invoke" (if arm then ''
		exec ${pkgs.bash}/bin/bash ${runnerSource}/scripts/run-arm64-test.bash \
			${pkgs.qemu-user}/bin/qemu-aarch64 ${wine}/bin/wine ${pkgs.bash}/bin/bash -c '
				wine=$1; shift
				status=0
				timeout --kill-after=5s 120s "$wine/bin/wine" "$@" || status=$?
				timeout --kill-after=5s 30s "$wine/bin/wineserver" -w || exit 1
				exit "$status"
			' arm64-wine ${wine} "$@"
	'' else ''
		status=0
		${pkgs.coreutils}/bin/timeout --kill-after=5s 120s ${wine}/bin/wine "$@" || status=$?
		${pkgs.coreutils}/bin/timeout --kill-after=5s 30s ${wine}/bin/wineserver -w || exit 1
		exit "$status"
	'');
	qualifyTarget = drv: drv.overrideAttrs (old: {
		nativeBuildInputs = (old.nativeBuildInputs or []) ++ pkgs.lib.optional arm pkgs.util-linux;
		# The provider's target-prefixed strip can leave CRT DWARF sections in
		# ARM64 PE files. Run the native COFF-aware tool explicitly and require
		# success; the final independent byte scan still rejects store paths.
		postFixup = (old.postFixup or "") + pkgs.lib.optionalString arm ''
			if [ -d "$out/bin" ]; then
				while IFS= read -r -d "" executable; do
					${pkgs.llvmPackages.llvm}/bin/llvm-strip --strip-debug "$executable"
				done < <(find "$out/bin" -type f -name '*.exe' -print0)
			fi
		'';
		# Rust supports this target; the pinned Nix provider's list predates it.
		meta = (old.meta or {}) // pkgs.lib.optionalAttrs arm { platforms = (old.meta.platforms or []) ++ [ "aarch64-windows" ]; };
	});
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
		${invokeWine} "$@" > "$output" 2> "$errors" || status=$?
		cat "$output"
		cat "$errors" >&2
		${pkgs.lib.optionalString receipt ''
			if [ "$status" -eq 0 ] && ! grep -F 'test result: ok.' "$output" > /dev/null; then
				printf 'FAIL Windows Rust executable produced no affirmative test receipt\n' >&2; exit 1
			fi
		''}
		exit "$status"
	'';
	library = debug: qualifyTarget (import ../rust/library.nix { pkgs = targetPkgs; inherit sdk buildStamp debug; });
	releaseLibrary = library false;
	debugLibrary = library true;
	frontend = debug: lib: qualifyTarget (import ../rust/cli.nix {
		pkgs = targetPkgs; library = lib; inherit debug buildStamp;
		runner = [ (runWine true) ];
	});
	release = rustProduct "release" (frontend false releaseLibrary) releaseLibrary;
	debug = rustProduct "debug" (frontend true debugLibrary) debugLibrary;
	products = [ release debug ];
	abiConsumers = map (lib: qualifyTarget (import ../rust/c-api-consumer.nix {
		pkgs = targetPkgs; library = lib; oracle = builtins.head oracles;
		runner = [ (runWine false) ];
	})) [ releaseLibrary debugLibrary ];
	# Exercise the real panic boundary on each Windows runtime. A library that
	# links successfully could still have a broken platform unwind path.
	boundaryTests = map (lib: qualifyTarget (lib.overrideAttrs (old: {
		pname = "difz-windows-${arch}-boundary-tests";
		"CARGO_TARGET_${pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] sdk.rustTarget)}_RUNNER" = "${runWine true}";
		buildPhase = ''
			runHook preBuild
			cmp ${buildStamp.json} ${sdk}/nix-support/build-provenance.json
			export CC=false CXX=false AR=false
			cargo test --color never --locked --offline --target ${sdk.rustTarget} \
				${pkgs.lib.optionalString (lib.rustProfile == "release") "--release"} -p difz-c-api --lib
			runHook postBuild
		'';
		installPhase = ''
			printf 'PASS real Windows Rust ownership and panic boundary\n' > "$out"
		'';
	}))) [ releaseLibrary debugLibrary ];
	fileCheck = import ./windows-emulated.nix { inherit pkgs products oracles wrongArchControl arch; };
	verificationSource = pkgs.lib.fileset.toSource {
		root = ../.;
		fileset = pkgs.lib.fileset.unions [ ../scripts/build-selection.bash ../scripts/verify-build-output.bash ];
	};
in assert builtins.elem arch [ "amd64" "arm64" ]; {
	packages = { "windows-${arch}-rust-release" = release; "windows-${arch}-rust-debug" = debug; };
	check = pkgs.runCommand "difz-windows-rust-${arch}-check" {
		nativeBuildInputs = with pkgs; [ bash coreutils gnugrep gnused binutils llvmPackages.llvm file jq ];
		passthru = { inherit products abiConsumers boundaryTests sdk; inherit (fileCheck) source execution; };
	} ''
		test -f ${fileCheck}
		for receipt in ${pkgs.lib.escapeShellArgs (map toString boundaryTests)}; do
			grep -Fx 'PASS real Windows Rust ownership and panic boundary' "$receipt"
		done
		for consumer in ${pkgs.lib.escapeShellArgs (map toString abiConsumers)}; do
			test -x "$consumer/bin/difz-rust-abi-consumer.exe"
			grep -Fx 'PASS packaged C ABI execution and export checks' "$consumer/nix-support/abi-check-passed"
		done
		source ${verificationSource}/scripts/build-selection.bash
		source ${verificationSource}/scripts/verify-build-output.bash
		for product in ${pkgs.lib.escapeShellArgs (map toString products)}; do
			profile=$(cat "$product/nix-support/rust-profile")
			difz_verify_product "$product" rust mswin-${arch} gnu "$profile" linux-amd64
			if difz_verify_product "$product" rust mswin-${arch} musl "$profile" linux-amd64 > wrong-variant-out 2> wrong-variant-error; then
				printf 'FAIL Windows Rust product accepted an incompatible ABI variant\n' >&2; exit 1
			fi
			grep -F 'Rust SDK ABI disagrees with selected variant' wrong-variant-error
		done
		for binary in ${pkgs.lib.escapeShellArgs ((map (p: "${p}/bin/difz.exe") products) ++ (map (p: "${p}/bin/difz-rust-abi-consumer.exe") abiConsumers))}; do
			if LC_ALL=C grep -aF '/nix/store/' "$binary" > /dev/null; then
				printf 'FAIL Windows Rust executable contains a Nix store path\n' >&2; exit 1
			fi
			llvm-readobj --coff-imports "$binary" | sed -n 's/^[[:space:]]*Name: //p' > imports
			test -s imports
			while IFS= read -r dll; do
				case "$dll" in
					KERNEL32.dll|msvcrt.dll|ntdll.dll|USERENV.dll|WS2_32.dll|api-ms-win-core-synch-l1-2-0.dll|bcryptprimitives.dll) :;;
					api-ms-win-crt-private-l1-1-0.dll|api-ms-win-crt-runtime-l1-1-0.dll|api-ms-win-crt-stdio-l1-1-0.dll|api-ms-win-crt-locale-l1-1-0.dll|api-ms-win-crt-heap-l1-1-0.dll|api-ms-win-crt-string-l1-1-0.dll|api-ms-win-crt-math-l1-1-0.dll|api-ms-win-crt-environment-l1-1-0.dll) :;;
					*) printf 'FAIL unexpected Windows Rust runtime DLL: %s\n' "$dll" >&2; exit 1;;
				esac
			done < imports
		done
		printf 'PASS Windows Rust optimized/Debug CLI, external C ABI, shared file acceptance and system-only imports\n'
		touch "$out"
	'';
}
