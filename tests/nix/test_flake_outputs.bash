#!/usr/bin/env bash

# Contract test for difz's supported native flake outputs.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FLAKE_REF="${FLAKE_REF:-$ROOT_DIR}"
EXPECTED='["aarch64-darwin","aarch64-linux","x86_64-linux"]'
EXPECTED_RANDOM_INPUTS='["random-luajit"]'
EXPECTED_RANDOM_REV='a758c902143f8f1dc08c3f33964b8fde7e4a2218'
EXPECTED_CI_TEST_COMMAND='./test'
EXPECTED_CI_BADGE='[![CI](https://github.com/pmarreck/difz/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/difz/actions/workflows/ci.yml)'

if ! grep -Fqx -- "$EXPECTED_CI_BADGE" "$ROOT_DIR/README.md"; then
	printf 'FAIL README GitHub CI badge\n' >&2
	printf '     expected: %s\n' "$EXPECTED_CI_BADGE" >&2
	exit 1
fi

printf 'PASS README GitHub CI badge targets ci.yml on yolo\n'

ci_test_command=$(awk '
	/^[[:space:]]*-[[:space:]]+name:[[:space:]]+Test[[:space:]]*$/ {
		in_test_step = 1
		next
	}
	in_test_step && /^[[:space:]]+run:[[:space:]]*/ {
		sub(/^[[:space:]]+run:[[:space:]]*/, "")
		print
		exit
	}
' "$ROOT_DIR/.github/workflows/ci.yml")

if [ "$ci_test_command" != "$EXPECTED_CI_TEST_COMMAND" ]; then
	printf 'FAIL GitHub CI Test command\n' >&2
	printf '     expected: %s\n' "$EXPECTED_CI_TEST_COMMAND" >&2
	printf '     actual:   %s\n' "$ci_test_command" >&2
	exit 1
fi

printf 'PASS GitHub CI Test command: %s\n' "$ci_test_command"

actual=$(nix eval --json --apply 'outputs: builtins.attrNames outputs' "$FLAKE_REF#packages" 2>/dev/null)
rc=$?

if [ "$rc" -ne 0 ]; then
	printf 'FAIL flake package systems could not be evaluated\n' >&2
	exit 1
fi

if [ "$actual" != "$EXPECTED" ]; then
	printf 'FAIL flake package systems\n' >&2
	printf '     expected: %s\n' "$EXPECTED" >&2
	printf '     actual:   %s\n' "$actual" >&2
	exit 1
fi

printf 'PASS flake package systems: %s\n' "$actual"

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
random_inputs=$(nix eval --json \
	--apply 'drv: builtins.filter (name: builtins.match "^random($|-).*" name != null) (map (input: input.pname or input.name or "") drv.nativeBuildInputs)' \
	"$FLAKE_REF#checks.${system}.benchmark-contract" 2>/dev/null)
rc=$?

if [ "$rc" -ne 0 ]; then
	printf 'FAIL benchmark random package could not be evaluated\n' >&2
	exit 1
fi

if [ "$random_inputs" != "$EXPECTED_RANDOM_INPUTS" ]; then
	printf 'FAIL benchmark random package\n' >&2
	printf '     expected inputs: %s\n' "$EXPECTED_RANDOM_INPUTS" >&2
	printf '     actual inputs:   %s\n' "$random_inputs" >&2
	exit 1
fi

printf 'PASS benchmark random package inputs: %s\n' "$random_inputs"

random_rev=$(nix eval --impure --raw --expr \
	"(builtins.getFlake \"$FLAKE_REF\").inputs.random.rev" 2>/dev/null)
rc=$?

if [ "$rc" -ne 0 ]; then
	printf 'FAIL random input revision could not be evaluated\n' >&2
	exit 1
fi

if [ "$random_rev" != "$EXPECTED_RANDOM_REV" ]; then
	printf 'FAIL random input revision\n' >&2
	printf '     expected: %s\n' "$EXPECTED_RANDOM_REV" >&2
	printf '     actual:   %s\n' "$random_rev" >&2
	exit 1
fi

printf 'PASS random input revision: %s\n' "$random_rev"

# Read the library pin independently of the flake's benchmark packaging.
zstd_url=$(awk '/\.zstdz = / { in_zstd = 1 } in_zstd && /\.url = / { split($0, fields, "\""); print fields[2]; exit }' "$ROOT_DIR/build.zig.zon")
shell_zstd_url=$(nix eval --raw \
	--apply 'shell: (builtins.head (builtins.filter (input: (input.pname or "") == "zstd") shell.nativeBuildInputs)).src.url' \
	"$FLAKE_REF#devShells.${system}.default" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$zstd_url" ] || [ "$shell_zstd_url" != "$zstd_url" ]; then
	printf 'FAIL benchmark CLI must use the zstdz library source pin\n' >&2
	printf '     expected: %s\n     actual:   %s\n' "$zstd_url" "$shell_zstd_url" >&2
	exit 1
fi
printf 'PASS benchmark CLI shares the zstdz library source pin\n'

if ! nix eval --raw "$FLAKE_REF#checks.${system}.windows-gnu.name" >/dev/null 2>&1; then
	printf 'FAIL windows-gnu cross check is missing\n' >&2
	exit 1
fi
printf 'PASS windows-gnu cross check is declared\n'

if ! nix eval --raw "$FLAKE_REF#packages.aarch64-linux.default.name" >/dev/null 2>&1; then
	printf 'FAIL aarch64-linux package does not evaluate\n' >&2
	exit 1
fi
printf 'PASS aarch64-linux package evaluates\n'

if [ ! -x "$ROOT_DIR/fuzz" ]; then
	printf 'FAIL ./fuzz is not an executable fuzzing suite\n' >&2
	exit 1
fi
printf 'PASS ./fuzz is executable\n'

rust_tools=$(nix eval --json \
	--apply 'shell: builtins.sort builtins.lessThan (builtins.filter (name: builtins.elem name [ "cargo" "rustc" ]) (map (input: input.pname or input.name or "") shell.nativeBuildInputs))' \
	"$FLAKE_REF#devShells.${system}.default" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] || [ "$rust_tools" != '["cargo","rustc"]' ]; then
	printf 'FAIL Rust interoperability checks require declared cargo and rustc tools\n' >&2
	printf '     actual: %s\n' "$rust_tools" >&2
	exit 1
fi
printf 'PASS Rust interoperability checks have declared cargo and rustc tools\n'
