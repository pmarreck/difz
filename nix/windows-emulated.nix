{ pkgs, products, oracles, armControl }:
let
	wine = pkgs.wine64Packages.minimal;
	source = pkgs.lib.fileset.toSource {
		root = ../.;
		fileset = ../tests/acceptance/cross-apply;
	};
	wrapped = map (product: pkgs.writeShellScript "difz-windows-amd64" ''
		exec ${wine}/bin/wine ${product}/bin/difz.exe "$@"
	'') products;
in pkgs.runCommand "difz-windows-amd64-wine-check" {
	inherit source;
	nativeBuildInputs = with pkgs; [ bash coreutils diffutils findutils gnugrep file ];
	passthru = { inherit products wine; execution = "wine-amd64-linux"; };
} ''
	export HOME="$TMPDIR/home" WINEPREFIX="$TMPDIR/wine-prefix" DIFZ_LANG=en
	export WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES='mscoree,mshtml='
	export DISPLAY= WAYLAND_DISPLAY= DBUS_SESSION_BUS_ADDRESS=
	mkdir -p "$HOME"
	for binary in ${pkgs.lib.escapeShellArgs (map (p: "${p}/bin/difz.exe") products)}; do
		file -Lb "$binary" | grep -F 'x86-64' > /dev/null
		OS=macos ARCH=arm64 PF=macos-arm64 VARIANT=conflicting \
			timeout --kill-after=5s 90s ${wine}/bin/wine "$binary" --about > "$TMPDIR/about" 2> "$TMPDIR/about-error"
		test "$(wc -l < "$TMPDIR/about")" -eq 1
		grep -F 'PF=mswin-amd64 VARIANT=gnu' "$TMPDIR/about"
	done
	# The real ARM64 PE must not be mistaken for an AMD64 execution proof.
	if timeout --kill-after=5s 30s ${wine}/bin/wine ${armControl}/bin/difz.exe --about > "$TMPDIR/wrong-arch-out" 2> "$TMPDIR/wrong-arch-error"; then
		printf 'FAIL AMD64 Wine accepted ARM64 control\n' >&2; exit 1
	fi
	timeout --kill-after=5s 180s bash "$source/tests/acceptance/cross-apply" ${builtins.elemAt oracles 0}/bin/difz ${builtins.elemAt wrapped 0} --files-only
	timeout --kill-after=5s 180s bash "$source/tests/acceptance/cross-apply" ${builtins.elemAt oracles 1}/bin/difz ${builtins.elemAt wrapped 1} --files-only
	mkdir "$TMPDIR/binary-stream"
	cd "$TMPDIR/binary-stream"
	printf '\000\377\r\nsource\032\000dictionary\377' > source
	printf '\000\377\r\ntarget\032\000dictionary\377new\000\377' > target
	for executable in ${pkgs.lib.escapeShellArgs (map toString wrapped)}; do
		"$executable" --no-progress source target -o patch
		"$executable" --patch --no-progress source patch -o @stdout > actual
		cmp target actual
	done
	printf 'PASS Windows AMD64 file acceptance and binary stdout; execution=wine-amd64-linux\n'
	touch "$out"
''
