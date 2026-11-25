{ pkgs, debugCli, releaseCli, oracle }:
let
	pf = (if pkgs.stdenv.hostPlatform.isDarwin then "macos" else "linux") + "-" + (if pkgs.stdenv.hostPlatform.isx86_64 then "amd64" else "arm64");
	variant = if pkgs.stdenv.hostPlatform.isLinux then (if pkgs.stdenv.hostPlatform.isMusl then "musl" else "gnu") else null;
	oracleVariant = if pkgs.stdenv.hostPlatform.isLinux then "musl" else null;
in pkgs.runCommand "difz-rust-cli-check" {
	src = pkgs.lib.fileset.toSource { root = ../.; fileset = ../tests/cli/test_cli.bash; };
	nativeBuildInputs = with pkgs; [ bash coreutils diffutils gnugrep ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.binutils ];
} ''
	export HOME="$TMPDIR/home" DIFZ_LANG=en
	mkdir -p "$HOME"
	for product in ${releaseCli} ${debugCli}; do
		test -s "$product/lib/libdifz_rust.a"
		test -s "$product/include/difz-rust.h"
		test -s "$product/nix-support/rust-target"
		grep -Fx '${pkgs.stdenv.hostPlatform.rust.rustcTarget}' "$product/nix-support/rust-target"
	done
	cmp ${releaseCli}/include/difz-rust.h ${debugCli}/include/difz-rust.h
	grep -Fx release ${releaseCli}/nix-support/rust-profile
	grep -Fx debug ${debugCli}/nix-support/rust-profile
	errors=0
	if ! DIFZ=${debugCli}/bin/difz DIFZ_TEST_DIRECTORY_OMIT=timestamps bash "$src/tests/cli/test_cli.bash" > "$TMPDIR/cli.log" 2>&1; then
		cat "$TMPDIR/cli.log" >&2; errors=$((errors + 1))
	else
		tail -3 "$TMPDIR/cli.log"
	fi
	if ! OS=macos ARCH=arm64 PF=macos-arm64 PLATFORM=macos-arm64 VARIANT=conflicting ${releaseCli}/bin/difz --about > "$TMPDIR/about" 2> "$TMPDIR/about-errors"; then errors=$((errors + 1)); fi
	if [ "$(wc -l < "$TMPDIR/about")" -ne 1 ] || ! grep -F 'PF=${pf}${pkgs.lib.optionalString (variant != null) " VARIANT=${variant}"}' "$TMPDIR/about" > /dev/null; then
		cat "$TMPDIR/about" >&2; errors=$((errors + 1))
	fi
	if ! OS=macos ARCH=arm64 PF=macos-arm64 PLATFORM=macos-arm64 VARIANT=conflicting ${oracle}/bin/difz --about > "$TMPDIR/oracle-about" 2> "$TMPDIR/oracle-about-errors"; then errors=$((errors + 1)); fi
	if [ "$(wc -l < "$TMPDIR/oracle-about")" -ne 1 ] || ! grep -F 'PF=${pf}${pkgs.lib.optionalString (oracleVariant != null) " VARIANT=${oracleVariant}"}' "$TMPDIR/oracle-about" > /dev/null; then
		printf 'FAIL original CLI compiled target identity\n' >&2
		cat "$TMPDIR/oracle-about" >&2; errors=$((errors + 1))
	fi
	${pkgs.lib.optionalString (variant == null) ''
		if grep -F 'VARIANT=' "$TMPDIR/about"; then errors=$((errors + 1)); fi
	''}
	work="$TMPDIR/cross"
	mkdir -p "$work/source/nested" "$work/target/nested"
	printf 'source\000\377shared bytes' > "$work/source/data"
	printf 'target\000\200shared bytes' > "$work/target/data"
	printf 'added\000bytes' > "$work/target/nested/new"
	ln -s ../data "$work/target/nested/link"
	for kind in file directory; do
		options=()
		if [ "$kind" = file ]; then from="$work/source/data"; to="$work/target/data"; else
			from="$work/source"; to="$work/target"; options=(--omit-metadata xattr,acl,timestamps,finder,sparse,hardlink)
		fi
		if ! ${releaseCli}/bin/difz --no-progress "''${options[@]}" "$from" "$to" -o "$work/$kind-rust.patch"; then errors=$((errors + 1)); continue; fi
		if ! ${oracle}/bin/difz --no-progress "''${options[@]}" "$from" "$to" -o "$work/$kind-native.patch"; then errors=$((errors + 1)); continue; fi
		if ! cmp "$work/$kind-rust.patch" "$work/$kind-native.patch"; then errors=$((errors + 1)); fi
		if [ "$kind" = file ]; then
			if ! ${releaseCli}/bin/difz --inspect "$work/$kind-rust.patch" > "$work/rust-inspect" || ! ${oracle}/bin/difz --inspect "$work/$kind-rust.patch" > "$work/native-inspect" || ! cmp "$work/rust-inspect" "$work/native-inspect"; then errors=$((errors + 1)); fi
		fi
		if ! ${oracle}/bin/difz --patch --no-progress "$from" "$work/$kind-rust.patch" -o "$work/$kind-native-output"; then errors=$((errors + 1)); fi
		if ! ${releaseCli}/bin/difz --patch --no-progress "$from" "$work/$kind-native.patch" -o "$work/$kind-rust-output"; then errors=$((errors + 1)); fi
		if [ "$kind" = file ]; then
			if ! cmp "$to" "$work/$kind-rust-output" || ! cmp "$to" "$work/$kind-native-output"; then errors=$((errors + 1)); fi
		else
			if ! diff -r "$to" "$work/$kind-rust-output" || ! diff -r "$to" "$work/$kind-native-output"; then errors=$((errors + 1)); fi
		fi
	done
	${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
		if readelf -d ${releaseCli}/bin/difz | grep NEEDED | grep -Ei 'zstd|difz'; then errors=$((errors + 1)); fi
		if ! readelf -h ${releaseCli}/bin/difz | grep -F '${if pkgs.stdenv.hostPlatform.isx86_64 then "Advanced Micro Devices X86-64" else "AArch64"}' > /dev/null; then errors=$((errors + 1)); fi
	''}
	if [ "$errors" -ne 0 ]; then exit "$errors"; fi
	printf 'PASS Rust CLI: original suite, target identity, byte-identical file/tree patches and cross-apply\n'
	touch "$out"
''
