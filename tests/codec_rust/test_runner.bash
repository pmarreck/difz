#!/usr/bin/env bash
# Exercise the prepared-binary boundary with controlled process adapters.
set -u

runner="$(cd "$(dirname "$0")" && pwd)/test"
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-codec-runner.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/decoys" "$work/directory" || exit 1
export RUNNER_TEST_LOG="$work/invocations"
for compiler in cargo rustc cc zig; do
	printf '#!%s\n' "$BASH" > "$work/decoys/$compiler"
	cat >> "$work/decoys/$compiler" <<'DECOY'
printf 'compiler invoked\n' >> "$RUNNER_TEST_LOG"
exit 99
DECOY
	chmod +x "$work/decoys/$compiler" || exit 1
done
printf '#!%s\n' "$BASH" > "$work/prepared"
cat >> "$work/prepared" <<'PREPARED'
printf 'oracle=%s\n' "$DIFZ_ORACLE" >> "$RUNNER_TEST_LOG"
printf 'arg=%s\n' "$@" >> "$RUNNER_TEST_LOG"
exit "${RUNNER_TEST_EXIT:-0}"
PREPARED
chmod +x "$work/prepared" || exit 1
cp "$work/prepared" "$work/prepared with spaces" || exit 1
printf 'not executable\n' > "$work/nonexec" || exit 1
export PATH="$work/decoys:$PATH"
paths=("$work/prepared" "$work/prepared with spaces" "$work/missing" "$work/directory" "$work/nonexec")
for oracle_index in 0 1 2 3 4; do
	for test_index in 0 1 2 3 4; do
		: > "$RUNNER_TEST_LOG"
		DIFZ_ORACLE="${paths[$oracle_index]}" DIFZ_CODEC_TEST="${paths[$test_index]}" \
			bash "$runner" 'argument with spaces' --test-threads=1 > "$work/stdout" 2> "$work/stderr"
		status=$?
		if [ "$oracle_index" -lt 2 ] && [ "$test_index" -lt 2 ]; then
			if [ "$status" -ne 0 ] || [ -s "$work/stdout" ] || [ -s "$work/stderr" ]; then
				printf 'FAIL prepared codec invocation (%s,%s): status %s\n' "$oracle_index" "$test_index" "$status" >&2
				exit 1
			fi
			printf 'oracle=%s\narg=argument with spaces\narg=--test-threads=1\n' "${paths[$oracle_index]}" > "$work/expected"
			cmp -s "$work/expected" "$RUNNER_TEST_LOG" || { printf 'FAIL codec invocation arguments\n' >&2; exit 1; }
		else
			if [ "$status" -eq 0 ] || [ -s "$RUNNER_TEST_LOG" ] || [ -s "$work/stdout" ] || [ ! -s "$work/stderr" ]; then
				printf 'FAIL invalid prepared artifact classification (%s,%s)\n' "$oracle_index" "$test_index" >&2
				exit 1
			fi
		fi
	done
done
RUNNER_TEST_EXIT=23 DIFZ_ORACLE="$work/prepared" DIFZ_CODEC_TEST="$work/prepared" \
	bash "$runner" > "$work/stdout" 2> "$work/stderr"
status=$?
if [ "$status" -ne 23 ] || [ -s "$work/stdout" ] || [ -s "$work/stderr" ]; then
	printf 'FAIL prepared codec exit status propagation\n' >&2
	exit 1
fi
printf 'PASS prepared codec runner classifies artifacts, preserves arguments and status, and invokes no compiler\n'
