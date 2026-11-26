{ pkgs, products, oracles, wrongArchControl, arch ? "amd64" }:
let
	armPkgs = import pkgs.path { system = "aarch64-linux"; };
	config = {
		amd64 = {
			wine = pkgs.wine64Packages.minimal;
			header = "x86-64";
			execution = "wine-amd64-linux";
		};
		arm64 = {
			wine = armPkgs.wine64Packages.minimal;
			header = "Aarch64";
			execution = "wine-arm64-qemu-user";
		};
	}.${arch};
	inherit (config) wine;
	runner = [ "${wine}/bin/wine" ];
	server = [ "${wine}/bin/wineserver" ];
	source = pkgs.lib.fileset.toSource {
		root = ../.;
		fileset = pkgs.lib.fileset.unions [
			../tests/acceptance/cross-apply ../scripts/run-arm64-test.bash
			../scripts/run-tests-isolated ../tests/integration/test_isolation.bash
			../tests/integration/test-arm64-isolation.bash
		];
	};
	wrapped = map (product: pkgs.writeShellScript "difz-windows-${arch}" ''
		exec ${pkgs.lib.escapeShellArgs runner} ${product}/bin/difz.exe "$@"
	'') products;
	body = pkgs.writeShellScript "difz-windows-${arch}-file-tests" ''
	set -uo pipefail
	fail() { printf 'FAIL Windows ${arch} acceptance: %s\n' "$*" >&2; exit 1; }
	export HOME="$TMPDIR/home" WINEPREFIX="$TMPDIR/wine-prefix" DIFZ_LANG=en
	export WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES='mscoree,mshtml='
	export DISPLAY= WAYLAND_DISPLAY= DBUS_SESSION_BUS_ADDRESS=
	unset LD_LIBRARY_PATH LD_PRELOAD PROOT_NO_SECCOMP
	mkdir -p "$HOME" || fail 'private home'
	for binary in ${pkgs.lib.escapeShellArgs (map (p: "${p}/bin/difz.exe") products)}; do
		if ! file -Lb "$binary" | grep -F '${config.header}' > /dev/null; then
			file -Lb "$binary" >&2; printf 'FAIL ${arch} PE header\n' >&2; exit 1
		fi
		about_status=0
		OS=macos ARCH=${if arch == "arm64" then "amd64" else "arm64"} PF=macos-arm64 VARIANT=conflicting \
			timeout --kill-after=5s 90s ${pkgs.lib.escapeShellArgs runner} "$binary" --about > "$TMPDIR/about" 2> "$TMPDIR/about-error" || about_status=$?
		if [ "$about_status" -ne 0 ] || [ "$(wc -l < "$TMPDIR/about")" -ne 1 ] || ! grep -F 'PF=mswin-${arch} VARIANT=gnu' "$TMPDIR/about"; then
			cat "$TMPDIR/about" "$TMPDIR/about-error" >&2
			printf 'FAIL ${arch} compiled identity; exit=%s\n' "$about_status" >&2; exit 1
		fi
	done
	wrong_status=0
	timeout --kill-after=5s 30s ${pkgs.lib.escapeShellArgs runner} ${wrongArchControl}/bin/difz.exe --about > "$TMPDIR/wrong-arch-out" 2> "$TMPDIR/wrong-arch-error" || wrong_status=$?
	if grep -F 'PF=' "$TMPDIR/wrong-arch-out"; then
		printf 'FAIL ${arch} Wine ran the wrong-architecture control\n' >&2; exit 1
	fi
	case "$wrong_status" in
		# ARM64 Wine 11.0 reports STATUS_NOT_SUPPORTED but returns zero.
		# Require its actual loader rejection, never infer success from exit alone.
		0) if ! grep -F 'error c00000bb' "$TMPDIR/wrong-arch-error" > /dev/null; then
			cat "$TMPDIR/wrong-arch-error" >&2
			printf 'FAIL zero exit without wrong-architecture loader rejection\n' >&2; exit 1
		fi;;
		124|137) printf 'FAIL wrong-architecture control timed out\n' >&2; exit 1;;
		*) :;;
	esac
	timeout --kill-after=5s 180s bash "$source/tests/acceptance/cross-apply" ${builtins.elemAt oracles 0}/bin/difz ${builtins.elemAt wrapped 0} --files-only || fail 'optimized shared file cases'
	timeout --kill-after=5s 180s bash "$source/tests/acceptance/cross-apply" ${builtins.elemAt oracles 1}/bin/difz ${builtins.elemAt wrapped 1} --files-only || fail 'Debug shared file cases'
	mkdir "$TMPDIR/binary-stream" || fail 'binary stream directory'
	cd "$TMPDIR/binary-stream" || fail 'binary stream cwd'
	printf '\000\377\r\nsource\032\000dictionary\377' > source || fail 'binary source'
	printf '\000\377\r\ntarget\032\000dictionary\377new\000\377' > target || fail 'binary target'
	for executable in ${pkgs.lib.escapeShellArgs (map toString wrapped)}; do
		"$executable" --no-progress source target -o patch || fail 'binary stdout encoder'
		"$executable" --patch --no-progress source patch -o @stdout > actual || fail 'binary stdout decoder'
		cmp target actual || fail 'binary stdout differs'
	done
	# Wait for this private prefix's server rather than returning with its
	# background processes still live. Namespace teardown is the final boundary.
	timeout --kill-after=5s 30s ${pkgs.lib.escapeShellArgs server} -w || fail 'private server completion'
	printf 'PASS Windows ${arch} file acceptance and binary stdout; execution=${config.execution}\n'
	touch "$out" || fail 'result marker'
	'';
in pkgs.runCommand "difz-windows-${arch}-wine-check" {
	inherit source;
	nativeBuildInputs = with pkgs; [ bash coreutils diffutils findutils gnugrep file util-linux bubblewrap ];
	passthru = { inherit products wine; inherit (config) execution; };
} (if arch == "arm64" then ''
	bash "$source/tests/integration/test-arm64-isolation.bash" "$source" ${pkgs.qemu-user}/bin/qemu-aarch64 ${wine}/bin/wine
	bash "$source/scripts/run-arm64-test.bash" ${pkgs.qemu-user}/bin/qemu-aarch64 ${wine}/bin/wine bash ${body}
'' else ''
	bash ${body}
'')
