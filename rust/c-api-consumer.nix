{ pkgs, library, oracle, runner ? [] }:
let
	cross = !(pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform);
	binary = "abi-consumer${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isWindows ".exe"}";
	execute = pkgs.lib.escapeShellArgs (runner ++ [ "./${binary}" ]);
	llvmCoff = pkgs.stdenv.hostPlatform.isWindows && pkgs.stdenv.hostPlatform.isAarch64;
	nm = if llvmCoff then "${pkgs.buildPackages.llvmPackages.llvm}/bin/llvm-nm" else "nm";
	objdump = if llvmCoff then "${pkgs.buildPackages.llvmPackages.llvm}/bin/llvm-objdump" else "objdump";
in
assert pkgs.lib.assertMsg (!cross || runner != []) "foreign ABI acceptance requires an explicit execution runner";
(pkgs.stdenv.mkDerivation rec {
	pname = "difz-rust-abi-consumer";
	version = "0.1.0";
	# Only consumer source is present. Headers and the matching static library
	# must come from the packaged producer, never implementation source.
	src = pkgs.lib.fileset.toSource {
		root = ../.;
		fileset = ./c-api/tests/caller.c;
	};
	strictDeps = true;
	buildInputs = [ library ];
	nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows
		[ (if llvmCoff then pkgs.buildPackages.llvmPackages.llvm else pkgs.buildPackages.binutils) ];
	nativeCheckInputs = with pkgs.buildPackages; [ coreutils diffutils gnugrep gnused gawk ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.buildPackages.binutils ];
	doCheck = true;
	buildPhase = ''
		runHook preBuild
		${if pkgs.stdenv.hostPlatform.isWindows then ''
			read -r -a libs < ${library}/nix-support/native-static-libs
			test "''${#libs[@]}" -gt 0
		'' else ''
			libs=(-lpthread -lm ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "-ldl -lrt -lutil"} ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "-liconv -lresolv"})
		''}
		"$CC" -std=c11 -Wall -Wextra -Werror -UNDEBUG -I${library}/include \
			-c rust/c-api/tests/caller.c -o caller.o
		"$CC" caller.o ${library}/lib/libdifz_rust.a "''${libs[@]}" -o ${binary}
		runHook postBuild
	'';
	# runPhase would still skip checkPhase after stdenv disables doCheck for
	# a foreign target. Execute this same body directly during the build.
	postBuild = pkgs.lib.optionalString cross checkPhase;
	checkPhase = ''
		runHook preCheck
		mkdir "$TMPDIR/cases"
		${execute} "$TMPDIR/cases"
		${oracle}/bin/difz --patch --no-progress "$TMPDIR/cases/source" "$TMPDIR/cases/rust.patch" -o "$TMPDIR/cases/native.output"
		cmp "$TMPDIR/cases/target" "$TMPDIR/cases/native.output"
		${oracle}/bin/difz --no-progress "$TMPDIR/cases/source" "$TMPDIR/cases/target" -o "$TMPDIR/cases/native.patch"
		${execute} --apply-native "$TMPDIR/cases/native.patch"
		${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
			${oracle}/bin/difz --patch --no-progress "$TMPDIR/cases/tree-source" "$TMPDIR/cases/tree.patch" -o "$TMPDIR/cases/native-applied-rust-tree"
			cmp "$TMPDIR/cases/tree-target/data" "$TMPDIR/cases/native-applied-rust-tree/data"
			cmp "$TMPDIR/cases/tree-target/new" "$TMPDIR/cases/native-applied-rust-tree/new"
			${oracle}/bin/difz --no-progress --omit-metadata xattr,acl,timestamps,finder,sparse,hardlink "$TMPDIR/cases/tree-source" "$TMPDIR/cases/tree-target" -o "$TMPDIR/cases/native-tree.patch"
			cmp "$TMPDIR/cases/tree.patch" "$TMPDIR/cases/native-tree.patch"
			./abi-consumer --apply-native-tree "$TMPDIR/cases/native-tree.patch" "$TMPDIR/cases"
		''}
		${pkgs.lib.optionalString (pkgs.stdenv.hostPlatform.isLinux || pkgs.stdenv.hostPlatform.isWindows) ''
			# Discover every public namespaced export, then require matching public
			# declarations and genuine external references from this consumer.
			${nm} --defined-only --extern-only ${library}/lib/libdifz_rust.a 2> "$TMPDIR/nm-errors" |
				awk 'NF == 3 && $2 ~ /^[A-Za-z]$/ && $3 ~ /^difz_/ { print $3 }' | LC_ALL=C sort -u > exports
			grep -oE 'difz_[a-z_]+[[:space:]]*[(]' ${library}/include/difz-rust.h |
				sed -E 's/[[:space:]]*[(]$//' | LC_ALL=C sort -u > declarations
			test -s exports
			if ! diff -u declarations exports; then
				printf 'FAIL public ABI declarations differ from packaged exports\n' >&2; exit 1
			fi
			${nm} --undefined-only caller.o | awk '$1 == "U" && $2 ~ /^difz_/ { print $2 }' | LC_ALL=C sort -u > references
			if ! diff -u declarations references; then
				printf 'FAIL consumer lacks direct references to every public export\n' >&2; exit 1
			fi
			if ${nm} --defined-only --extern-only caller.o | awk 'NF == 3 && $2 ~ /^[A-Za-z]$/ && $3 ~ /^difz_/ { found=1 } END { exit !found }'; then
				printf 'FAIL consumer defines an implementation export\n' >&2; exit 1
			fi
			while IFS= read -r symbol; do
				# Wrapping redirects references to a deliberately missing symbol.
				# Success means the consumer did not really require that export.
				if "$CC" caller.o -Wl,--wrap="$symbol" ${library}/lib/libdifz_rust.a "''${libs[@]}" -o "$TMPDIR/missing-export" > "$TMPDIR/link-output" 2>&1; then
					printf 'FAIL unused public ABI export: %s\n' "$symbol" >&2; exit 1
				fi
				grep -F "__wrap_$symbol" "$TMPDIR/link-output" > /dev/null
			done < declarations
			if ${if pkgs.stdenv.hostPlatform.isWindows then "${objdump} -p ./${binary} | grep 'DLL Name:'" else "readelf -d ./abi-consumer | grep NEEDED"} | grep -Ei 'zstd|difz'; then
				printf 'FAIL ABI consumer has a dynamic difz/zstd dependency\n' >&2; exit 1
			fi
			printf 'PASS isolated ABI consumer: every discovered export required; missing-export controls fail\n'
		''}
		runHook postCheck
		printf 'PASS packaged C ABI execution and export checks\n' > "$TMPDIR/abi-check-passed"
	'';
	installPhase = ''
		test -s "$TMPDIR/abi-check-passed"
		install -Dm755 ${binary} "$out/bin/difz-rust-abi-consumer${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isWindows ".exe"}"
		install -Dm644 "$TMPDIR/abi-check-passed" "$out/nix-support/abi-check-passed"
	'';
}).overrideAttrs (old: pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
	buildInputs = (old.buildInputs or []) ++ (old.propagatedBuildInputs or []);
	propagatedBuildInputs = [];
	allowedReferences = [];
})
