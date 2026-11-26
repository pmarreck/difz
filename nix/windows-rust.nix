{ pkgs, buildStamp, zstdBuild, rustProduct, oracles, originals, wrongArchControl, arch ? "amd64" }:
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
		# Wine derives the Unix filename encoding from the host locale. Keep
		# Windows scratch on the caller's declared filesystem, not a prefix default.
		export LANG=C.UTF-8 LC_ALL=C.UTF-8
		export WINETEMP="Z:$TMPDIR/windows-temp" WINETMP="Z:$TMPDIR/windows-temp"
		mkdir -p "$TMPDIR/windows-temp" || exit 1
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
	unitTests = { name, package, receipt, expectedTests }: map (lib: qualifyTarget (lib.overrideAttrs (old: {
		pname = "difz-windows-${arch}-${name}-tests";
		"CARGO_TARGET_${pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] sdk.rustTarget)}_RUNNER" = "${runWine true}";
		buildPhase = ''
			runHook preBuild
			cmp ${buildStamp.json} ${sdk}/nix-support/build-provenance.json
			export CC=false CXX=false AR=false
			run_tests() {
				cargo test --color never --locked --offline --target ${sdk.rustTarget} \
					${pkgs.lib.optionalString (lib.rustProfile == "release") "--release"} -p ${package} --lib -- "$@"
			}
			status=0
			run_tests > "$TMPDIR/unit-output" 2> "$TMPDIR/unit-errors" || status=$?
			cat "$TMPDIR/unit-output"
			cat "$TMPDIR/unit-errors" >&2
			test "$status" -eq 0
			# A cfg mistake that discovers zero tests must not mint a receipt.
			grep -F 'test result: ok. ${toString expectedTests} passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;' "$TMPDIR/unit-output"
			runHook postBuild
		'';
		installPhase = ''
			printf '%s\n' ${pkgs.lib.escapeShellArg receipt} > "$out"
		'';
	}))) [ releaseLibrary debugLibrary ];
	boundaryTests = unitTests {
		name = "boundary"; package = "difz-c-api";
		expectedTests = 2;
		receipt = "PASS real Windows Rust ownership and panic boundary";
	};
	platformTestCount = 14;
	platformRunner = profile: pkgs.writeShellScript "difz-windows-platform-${arch}-${profile}-tests" ''
		set -uo pipefail
		# Nix deliberately denies xattr setters. Wine stores reparse points in
		# xattrs, so ./test executes these prepared binaries in host confinement.
		[[ $# == 0 ]] || { printf 'FAIL unexpected Windows test arguments\n' >&2; exit 1; }
		scratch=$(mktemp -d "''${TMPDIR:?}/difz-windows-${arch}-${profile}.XXXXXXXX") || exit 1
		export TMPDIR="$scratch"
		export DIFZ_WINDOWS_ORACLE="Z:${originals.${profile}}/bin/difz.exe"
		probe=$(mktemp "$TMPDIR/xattr-probe.XXXXXXXX") || exit 1
		${pkgs.attr}/bin/setfattr -n user.difz-wine-probe -v retained "$probe" || exit 1
		test "$(${pkgs.attr}/bin/getfattr --only-values -n user.difz-wine-probe "$probe")" = retained || exit 1
		run_tests() { ${runWine true} @EXECUTABLE@ --test-threads=1 "$@"; }
		if ! run_tests > "$TMPDIR/tests.out" 2> "$TMPDIR/tests.err"; then
			cat "$TMPDIR/tests.out" "$TMPDIR/tests.err" >&2; exit 1
		fi
		cat "$TMPDIR/tests.out"
		grep -F 'test result: ok. ${toString platformTestCount} passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;' "$TMPDIR/tests.out" || exit 1
		# The real harness succeeds with no selected tests. Its output must fail
		# the required-case receipt, rather than permitting a vacuous green run.
		if ! run_tests --exact __difz_absent_test_negative_control > "$TMPDIR/zero.out" 2> "$TMPDIR/zero.err"; then
			cat "$TMPDIR/zero.out" "$TMPDIR/zero.err" >&2; exit 1
		fi
		grep -F 'test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; ${toString platformTestCount} filtered out;' "$TMPDIR/zero.out" || exit 1
		if grep -F 'test result: ok. ${toString platformTestCount} passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;' "$TMPDIR/zero.out"; then
			printf 'FAIL zero-test harness satisfied the required-case receipt\n' >&2; exit 1
		fi
		printf 'PASS Windows ${arch} ${profile} pinned directory capabilities and zero-test control\n'
	'';
	platformTests = map (lib: qualifyTarget (lib.overrideAttrs (old: {
		pname = "difz-windows-${arch}-platform-tests";
		# QA wrappers intentionally reference pinned host runtimes. Production
		# executables and archives retain their independent no-store guards.
		allowedReferences = null;
		src = pkgs.lib.fileset.toSource {
			root = ../rust;
			fileset = pkgs.lib.fileset.unions [
				../rust/Cargo.toml ../rust/Cargo.lock ../rust/src ../rust/zstdz
				../rust/consumer ../rust/c-api ../rust/platform
			];
		};
		buildPhase = ''
			runHook preBuild
			cmp ${buildStamp.json} ${sdk}/nix-support/build-provenance.json
			export CC=false CXX=false AR=false
			if ! cargo test --color never --locked --offline --target ${sdk.rustTarget} \
				${pkgs.lib.optionalString (lib.rustProfile == "release") "--release"} -p difz-platform --lib --no-run --message-format=json > artifacts.json; then
				jq -r 'select(.reason == "compiler-message") | .message.rendered // empty' artifacts.json >&2; exit 1
			fi
			executable=$(jq -ser '[.[] | select(.reason == "compiler-artifact" and .target.name == "difz_platform" and .profile.test and .executable != null) | .executable] | if length == 1 then .[0] else error("expected one Windows platform test executable") end' artifacts.json)
			${runWine false} "$executable" --list > test-list.raw
			tr -d '\r' < test-list.raw > test-list
			test "$(grep -c '^windows::.*: test$' test-list)" -eq ${toString platformTestCount}
			grep -Fx '${toString platformTestCount} tests, 0 benchmarks' test-list
			runHook postBuild
		'';
		installPhase = ''
			runHook preInstall
			name=difz-windows-platform-${arch}-${lib.rustProfile}
			install -Dm755 "$executable" "$out/libexec/$name.exe"
			substitute ${platformRunner lib.rustProfile} "$out/libexec/$name-tests" \
				--replace-fail '@EXECUTABLE@' "$out/libexec/$name.exe"
			chmod +x "$out/libexec/$name-tests"
			install -Dm644 test-list "$out/nix-support/platform-test-list"
			printf 'PASS prepared Windows ${arch} ${lib.rustProfile} directory capability tests\n' > "$out/nix-support/platform-tests-prepared"
			runHook postInstall
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
		passthru = { inherit products abiConsumers boundaryTests platformTests sdk; inherit (fileCheck) source execution; };
	} ''
		test -f ${fileCheck}
		for receipt in ${pkgs.lib.escapeShellArgs (map toString boundaryTests)}; do
			grep -Fx 'PASS real Windows Rust ownership and panic boundary' "$receipt"
		done
		for prepared in ${pkgs.lib.escapeShellArgs (map toString platformTests)}; do
			grep -Ex 'PASS prepared Windows ${arch} (release|debug) directory capability tests' "$prepared/nix-support/platform-tests-prepared"
			grep -Fx '${toString platformTestCount} tests, 0 benchmarks' "$prepared/nix-support/platform-test-list"
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
