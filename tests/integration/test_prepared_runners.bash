#!/usr/bin/env bash
# Exhaust artifact states in-process; exercise the real dispatch boundary separately.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
source "$root/scripts/prepared-host-artifacts.bash" || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-prepared-runners.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
record="$work/executed"
mkdir -p "$work/tools" "$work/shapes" || exit 1
# Inner Bash must be recorded too: otherwise an escaped preflight can recurse
# into this contract before reaching any of the compiler/artifact stubs.
for tool in bash zig rustc cargo env luajit; do
	# shellcheck disable=SC2016
	printf '#!%s\nprintf called >> "$DIFZ_RUNNER_RECORD"\nexit 66\n' "$BASH" > "$work/tools/$tool" || exit 1
	chmod +x "$work/tools/$tool" || exit 1
done
# This is the Linux prepared-runner contract even when its source-bounded Nix
# check executes on another build host; native foreign adapters have separate gates.
printf '#!%s\nprintf "Linux\\n"\n' "$BASH" > "$work/tools/uname" || exit 1
chmod +x "$work/tools/uname" || exit 1
export DIFZ_RUNNER_RECORD="$record"
export PATH="$work/tools:$PATH"
slots=(bin/difz libexec/difz-unit-tests bin/difz-rust-caller bin/difz-core-consumer bin/difz-platform-tests libexec/difz-standalone-tests)
states=(valid missing directory non-executable)
combinations=1
# Each state has a distinct real filesystem fixture for every artifact. Select
# vectors of those immutable paths instead of recreating 4095 directory trees.
for ((index=0; index<${#slots[@]}; index++)); do
	mkdir -p "$work/shapes/$index" "$work/shapes/$index/directory" || exit 1
	ln -s "$work/tools/zig" "$work/shapes/$index/valid" || exit 1
	printf plain > "$work/shapes/$index/non-executable" || exit 1
	combinations=$((combinations * ${#states[@]}))
done
for ((code=0; code<combinations; code++)); do
	remainder=$code
	paths=()
	for ((index=0; index<${#slots[@]}; index++)); do
		paths+=("$work/shapes/$index/${states[$((remainder % ${#states[@]}))]}")
		remainder=$((remainder / ${#states[@]}))
	done
	difz_require_prepared_artifacts "${paths[@]}" > "$work/out" 2> "$work/err"
	status=$?
	if { [ "$code" -eq 0 ] && { [ "$status" -ne 0 ] || [ -s "$work/err" ]; }; } ||
		{ [ "$code" -ne 0 ] && { [ "$status" -eq 0 ] || [ ! -s "$work/err" ]; }; } || [ -e "$record" ]; then
		printf 'FAIL prepared artifact classification case %d\n' "$code" >&2
		exit 1
	fi
done
if difz_require_prepared_artifacts > "$work/out" 2> "$work/err" || [ ! -s "$work/err" ]; then
	printf 'FAIL empty artifact declaration was accepted\n' >&2; exit 1
fi
# Test every real entry-point slot with all its other prerequisites valid.
# A positive preflight witness also rejects an entry point that refuses everything.
check_entrypoint() {
	local entry=$1 prefix=$2 omitted shape slot status
	mkdir -p "$prefix/bin" "$prefix/libexec" || return 1
	for slot in "${slots[@]}"; do ln -s "$work/tools/zig" "$prefix/$slot" || return 1; done
	# Trace the boundary before Linux-only clocks are used. This classifier check
	# is portable; it does not claim native behavioral execution on other hosts.
	DIFZ_HOST_TESTS="$prefix" TMPDIR="$work" TEST_WORKSPACE="$work" \
		"$BASH" -x "$entry" > "$work/out" 2> "$work/err"
	if ! grep -Fxq '+ errors=0' "$work/err"; then
		printf 'FAIL complete artifact set did not pass preflight\n' >&2; return 1
	fi
	# Only remove owned fixture links/markers; never change a prepared artifact.
	[ ! -e "$record" ] || rm -- "$record" || return 1
	for omitted in "${slots[@]}"; do
		rm -- "$prefix/$omitted" || return 1
		for shape in missing directory non-executable; do
			case "$shape" in
				missing) :;;
				directory) mkdir "$prefix/$omitted" || return 1;;
				non-executable) printf plain > "$prefix/$omitted" || return 1;;
			esac
			DIFZ_HOST_TESTS="$prefix" TMPDIR="$work" TEST_WORKSPACE="$work" \
				"$BASH" "$entry" > "$work/out" 2> "$work/err"
			status=$?
			if [ "$status" -eq 0 ] || [ -e "$record" ] ||
				! grep -Fxq "FAIL Nix-prepared host artifact is missing: $prefix/$omitted" "$work/err"; then
				printf 'FAIL prepared entry-point preflight: %s %s\n' "$omitted" "$shape" >&2
				return 1
			fi
			case "$shape" in
				directory) rmdir "$prefix/$omitted" || return 1;;
				non-executable) rm -- "$prefix/$omitted" || return 1;;
			esac
		done
		ln -s "$work/tools/zig" "$prefix/$omitted" || return 1
	done
}
check_entrypoint "$root/tests/run-prepared-host" "$work/prefix with spaces" || exit 1
# These omission mutants must be caught by the entry-point controls themselves.
# In particular, another missing prerequisite cannot mask a removed slot check.
mkdir -p "$work/mutants/tests" "$work/mutants/scripts" || exit 1
cp "$root/scripts/prepared-host-artifacts.bash" "$work/mutants/scripts/" || exit 1
for ((index=0; index<${#slots[@]}; index++)); do
	sed "\|\"\$prefix/${slots[$index]}\"|d" "$root/tests/run-prepared-host" > "$work/mutants/tests/runner-$index" || exit 1
	if check_entrypoint "$work/mutants/tests/runner-$index" "$work/mutant-prefix-$index" > "$work/mutant-out" 2> "$work/mutant-err"; then
		printf 'FAIL omitted artifact check survived: %s\n' "${slots[$index]}" >&2; exit 1
	fi
	if ! grep -Fxq "FAIL prepared entry-point preflight: ${slots[$index]} missing" "$work/mutant-err"; then
		printf 'FAIL omission control failed for an unrelated reason: %s\n' "${slots[$index]}" >&2; exit 1
	fi
	[ ! -e "$record" ] || rm -- "$record" || exit 1
done
for shape in missing directory non-executable; do
	case "$shape" in
		missing) caller="$work/absent";;
		directory) caller="$work";;
		non-executable) caller="$work/plain"; printf plain > "$caller";;
	esac
	DIFZ_RUST_CALLER="$caller" "$BASH" "$root/tests/ffi/test_rust_lib.bash" > "$work/out" 2> "$work/err"
	status=$?
	if [ "$status" -eq 0 ] || [ -e "$record" ] || [ ! -s "$work/err" ]; then
		printf 'FAIL prepared Rust consumer classification %s\n' "$shape" >&2; exit 1
	fi
done
for shape in missing directory non-executable; do
	prefix="$work/rust-cli-$shape"
	mkdir -p "$prefix/bin" || exit 1
	case "$shape" in
		missing) :;;
		directory) mkdir "$prefix/bin/difz-rust" || exit 1;;
		non-executable) printf plain > "$prefix/bin/difz-rust" || exit 1;;
	esac
	"$BASH" "$root/tests/run-host-tests" "$prefix" > "$work/out" 2> "$work/err"
	status=$?
	if [ "$status" -eq 0 ] || [ -e "$record" ] || [ ! -s "$work/err" ]; then
		printf 'FAIL prepared Rust CLI classification %s\n' "$shape" >&2; exit 1
	fi
	if ! grep -Fxq 'FAIL Nix-prepared Rust CLI artifact is missing: bin/difz-rust' "$work/err"; then
		printf 'FAIL Rust CLI preflight did not reject before other checks: %s\n' "$shape" >&2; exit 1
	fi
done
printf 'PASS prepared runners reject %d invalid artifact sets, all 18 entry-point paths, six omission mutants, and three invalid paths each for the Rust consumer and Rust CLI without execution\n' "$((combinations - 1))"
