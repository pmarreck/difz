#!/usr/bin/env bash

# Contract test for difz's supported native flake outputs.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FLAKE_REF="${FLAKE_REF:-$ROOT_DIR}"
EXPECTED='["aarch64-darwin","aarch64-linux","x86_64-linux"]'

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
