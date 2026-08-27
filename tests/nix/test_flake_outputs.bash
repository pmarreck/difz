#!/usr/bin/env bash

# Contract test for difz's supported native flake outputs.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FLAKE_REF="${FLAKE_REF:-$ROOT_DIR}"
EXPECTED='["aarch64-darwin","aarch64-linux","x86_64-linux"]'
EXPECTED_RANDOM_INPUTS='["random-luajit"]'
EXPECTED_RANDOM_REV='8ddd6aac19be75cacf09128cd3ea75faf9a08dc4'

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
