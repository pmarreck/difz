#!/usr/bin/env bash
# Contract test for supported outputs, using one immutable flake evaluation.
set -u
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FLAKE_REF="${FLAKE_REF:-$ROOT_DIR}"
EXPECTED='["aarch64-darwin","aarch64-linux","x86_64-linux"]'
EXPECTED_RANDOM_INPUTS='["random-luajit"]'
EXPECTED_RANDOM_REV='a758c902143f8f1dc08c3f33964b8fde7e4a2218'
EXPECTED_CI_TEST_COMMAND='./test'
EXPECTED_CI_BADGE='[![CI](https://github.com/pmarreck/difz/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/difz/actions/workflows/ci.yml)'
if ! grep -Fqx -- "$EXPECTED_CI_BADGE" "$ROOT_DIR/README.md"; then
	printf 'FAIL README GitHub CI badge\n' >&2; exit 1
fi
printf 'PASS README GitHub CI badge targets ci.yml on yolo\n'
ci_test_command=$(awk '
	/^[[:space:]]*-[[:space:]]+name:[[:space:]]+Test[[:space:]]*$/ { in_test_step = 1; next }
	in_test_step && /^[[:space:]]+run:[[:space:]]*/ {
		sub(/^[[:space:]]+run:[[:space:]]*/, ""); print; exit
	}
' "$ROOT_DIR/.github/workflows/ci.yml")
if [ "$ci_test_command" != "$EXPECTED_CI_TEST_COMMAND" ]; then
	printf 'FAIL GitHub CI Test command\n' >&2; exit 1
fi
printf 'PASS GitHub CI Test command: %s\n' "$ci_test_command"

# Resolve through Git-aware Nix metadata so ignored build caches never enter
# the source snapshot. Evaluating a plain working-directory path would copy them.
flake_metadata=$(nix flake metadata --json --no-update-lock-file "$FLAKE_REF" 2>/dev/null) || {
	printf 'FAIL flake metadata could not be evaluated without updating the lock\n' >&2; exit 1;
}
source_path=$(jq -er '.path | select(type == "string" and startswith("/nix/store/"))' <<< "$flake_metadata") || exit 1
contract=$(DIFZ_FLAKE_SNAPSHOT="$source_path" nix eval --impure --json --no-update-lock-file \
	--file "$ROOT_DIR/tests/nix/flake_contracts.nix" \
	--apply 'query: query { source = builtins.getEnv "DIFZ_FLAKE_SNAPSHOT"; }' 2>/dev/null) || {
	printf 'FAIL flake contract snapshot could not be evaluated\n' >&2; exit 1;
}
expect_json() {
	actual=$(jq -c "$1" <<< "$contract") || { printf 'FAIL invalid contract query\n' >&2; exit 1; }
	if [ "$actual" != "$2" ]; then
		printf 'FAIL %s\n     actual: %s\n' "$3" "$actual" >&2; exit 1
	fi
	printf 'PASS %s\n' "$3"
}
require_json() {
	if ! jq -e "$1" <<< "$contract" >/dev/null; then
		printf 'FAIL %s\n' "$2" >&2; exit 1
	fi
	printf 'PASS %s\n' "$2"
}
expect_json '.systems' "$EXPECTED" "flake package systems: $EXPECTED"
expect_json '.randomInputs' "$EXPECTED_RANDOM_INPUTS" "benchmark random package inputs: $EXPECTED_RANDOM_INPUTS"
random_rev=$(jq -er '.locks.nodes.random.locked.rev' <<< "$flake_metadata") || exit 1
if [ "$random_rev" != "$EXPECTED_RANDOM_REV" ]; then
	printf 'FAIL random input revision\n' >&2; exit 1
fi
printf 'PASS random input revision: %s\n' "$random_rev"
zstd_url=$(awk '/\.zstdz = / { in_zstd = 1 } in_zstd && /\.url = / { split($0, fields, "\""); print fields[2]; exit }' "$ROOT_DIR/build.zig.zon")
shell_zstd_url=$(jq -er '.zstdUrl' <<< "$contract") || exit 1
if [ -z "$zstd_url" ] || [ "$shell_zstd_url" != "$zstd_url" ]; then
	printf 'FAIL benchmark CLI must use the zstdz library source pin\n' >&2; exit 1
fi
printf 'PASS benchmark CLI shares the zstdz library source pin\n'
require_json '.windowsCheck | type == "string" and length > 0' 'windows-gnu cross check is declared'
require_json '.armPackage | type == "string" and length > 0' 'aarch64-linux package evaluates'
if [ ! -x "$ROOT_DIR/fuzz" ]; then printf 'FAIL ./fuzz is not an executable fuzzing suite\n' >&2; exit 1; fi
printf 'PASS ./fuzz is executable\n'
expect_json '.rustTools' '["cargo","rustc"]' 'Rust interoperability checks have declared cargo and rustc tools'
expect_json '.codecOutputs' '{"aarch64-darwin":["rust-codec-tests"],"aarch64-linux":["rust-codec-tests"],"x86_64-linux":["rust-codec-tests"]}' 'Rust codec packages are declared for every native system'
require_json '.codecCheck | type == "string" and length > 0' 'Rust codec runtime check is declared'
require_json '.hostOutputs | length == 3 and all(.[]; . == true)' 'native host test artifacts have declared Nix outputs'
require_json '.rustFfiCheck | type == "string" and length > 0' 'installed Rust consumer runtime has a declared Nix check'
require_json '.rustCoreCheck | type == "string" and length > 0' 'Rust core has a declared Nix check'
require_json '.buildWrapperCheck | type == "string" and length > 0' 'Nix build adapter has a declared check'
require_json '.debugPackages | length == 3 and all(.[]; . == true)' 'debug builds select the checked Nix artifact on every native system'
require_json '(.buildWrapperSource.required | length == 2 and all(.[]; . == true)) and (.buildWrapperSource.excluded | length == 5 and all(.[]; . == false))' 'build adapter source membership excludes unrelated path sets'
require_json '.rustCoreOutputs | length == 3 and all(.[]; . == true)' 'Rust core artifacts are declared for every native system'
require_json '(.rustCoreSource.required | length == 13 and all(.[]; . == true)) and (.rustCoreSource.excluded | length == 6 and all(.[]; . == false))' 'Rust core source membership includes native adapter and consumer, excluding unrelated path sets'
require_json '.crossApplyCheck | type == "string" and length > 0' 'cross-implementation acceptance has a declared Nix check'
require_json '(.crossApplySource.required | length == 2 and all(.[]; . == true)) and (.crossApplySource.excluded | length == 6 and all(.[]; . == false))' 'cross-apply source membership excludes unrelated path sets'
ci_targets=$(awk '{sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if ($0 != "" && $0 !~ /^#/) print}' "$ROOT_DIR/.mechatron-prime/targets") || exit 1
ci_targets=$(printf '%s\n' "$ci_targets" | LC_ALL=C sort) || exit 1
expected_ci_targets=$(jq -r '.ciTargets | sort | .[]' <<< "$contract") || exit 1
if [ "$ci_targets" != "$expected_ci_targets" ]; then
	printf 'FAIL Mechatron Prime CI targets must cover every declared native check\n' >&2; exit 1
fi
printf 'PASS Mechatron Prime CI target set covers every declared native check\n'
require_json '(.zigSource.required | length == 10 and all(.[]; . == true)) and (.zigSource.excluded | length == 8 and all(.[]; . == false))' 'Zig source membership classifies required and unrelated path sets'
require_json '(.benchmarkSource.required | length == 11 and all(.[]; . == true)) and (.benchmarkSource.excluded | length == 8 and all(.[]; . == false))' 'benchmark source membership classifies required and unrelated path sets'
