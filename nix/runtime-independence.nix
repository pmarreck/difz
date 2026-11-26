{ pkgs, products }:
let
	source = pkgs.lib.fileset.toSource {
		root = ../.;
		fileset = pkgs.lib.fileset.unions [ ../scripts/check-static-linux.bash ../tests/integration/test-standalone-linux.bash ];
	};
	# A real dynamic ELF is the negative loader control, not malformed bytes.
	dynamicControl = pkgs.runCommandCC "difz-dynamic-control" {} ''
		printf '#include <stdio.h>\nint main(void) { puts("dynamic control"); return 0; }\n' > control.c
		mkdir -p "$out/bin"
		"$CC" control.c -o "$out/bin/control"
	'';
	binaries = map (product: "${product}/bin/difz") products;
	runner = pkgs.writeShellScript "difz-standalone-tests" ''
		exec ${pkgs.bash}/bin/bash ${source}/tests/integration/test-standalone-linux.bash \
			${dynamicControl}/bin/control ${pkgs.lib.escapeShellArgs binaries}
	'';
in pkgs.runCommand "difz-runtime-independence-check" {
	inherit source;
	nativeBuildInputs = with pkgs; [ bash binutils coreutils diffutils gnugrep ];
	passthru = { inherit runner; };
} ''
	for binary in ${pkgs.lib.escapeShellArgs binaries}; do
		bash "$source/scripts/check-static-linux.bash" "$binary"
	done
	if bash "$source/scripts/check-static-linux.bash" ${dynamicControl}/bin/control > "$TMPDIR/control-output" 2>&1; then
		printf 'FAIL dynamic executable accepted\n' >&2; exit 1
	fi
	grep -F 'loader dependency' "$TMPDIR/control-output"
	# Valid ELF with a forbidden literal must fail independently of loader checks.
	cp ${builtins.head binaries} "$TMPDIR/embedded-path"
	chmod u+w "$TMPDIR/embedded-path"
	printf '/nix/store/forbidden-runtime-path' >> "$TMPDIR/embedded-path"
	if bash "$source/scripts/check-static-linux.bash" "$TMPDIR/embedded-path" > "$TMPDIR/bytes-output" 2>&1; then
		printf 'FAIL embedded Nix path accepted\n' >&2; exit 1
	fi
	grep -F 'embeds a Nix store path' "$TMPDIR/bytes-output"
	for shape in missing empty plain; do
		case "$shape" in empty) touch "$TMPDIR/$shape";; plain) printf plain > "$TMPDIR/$shape";; esac
		if [ -e "$TMPDIR/$shape" ]; then chmod +x "$TMPDIR/$shape"; fi
		if bash "$source/scripts/check-static-linux.bash" "$TMPDIR/$shape" > "$TMPDIR/invalid-output" 2>&1; then exit 1; fi
	done
	mkdir -p "$out/libexec"
	ln -s ${runner} "$out/libexec/difz-standalone-tests"
''
