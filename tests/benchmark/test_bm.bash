#!/usr/bin/env bash

# Behavioral tests for the benchmark driver. Exit code = failed test count.

set -u

ERRORS=0
TESTS=0
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="${TMPDIR:-/tmp}/difz_bm_tests_$$"
FAKE_BIN="$TEST_DIR/bin"
PINNED_RANDOM_BIN="${RANDOM_BIN:-random}"
PINNED_DIFZ="${DIFZ:-$ROOT_DIR/zig-out/bin/difz}"

pass() {
	TESTS=$((TESTS + 1))
	printf "  \033[32mPASS\033[0m %s\n" "$1"
}

fail() {
	TESTS=$((TESTS + 1))
	ERRORS=$((ERRORS + 1))
	printf "  \033[31mFAIL\033[0m %s\n" "$1"
	if [ "${2:-}" != "" ]; then
		printf "       %s\n" "$2"
	fi
}

cleanup() {
	rm -rf "$TEST_DIR"
}

trap cleanup EXIT
mkdir -p "$FAKE_BIN"

printf '#!%s\n' "$(type -P bash)" > "$FAKE_BIN/zig"
cat >> "$FAKE_BIN/zig" <<'EOF'
exit 0
EOF

printf '#!%s\n' "$(type -P bash)" > "$FAKE_BIN/random"
cat >> "$FAKE_BIN/random" <<'EOF'
case "${FAKE_RANDOM_MODE:-fail}" in
	fail)
		printf 'injected random failure\n' >&2
		exit 23
		;;
	truncate)
		printf 'x'
		exit 0
		;;
	exact)
		seed=''
		count=''
		binary=0
		while [ "$#" -gt 0 ]; do
			case "$1" in
				--seed)
					seed="${2:-}"
					shift 2
					;;
				-b)
					binary=1
					shift
					;;
				-c)
					count="${2:-}"
					shift 2
					;;
				*)
					printf 'unexpected random argument: %s\n' "$1" >&2
					exit 64
					;;
			esac
		done
		if [ "$seed" = "" ] || [ "$count" = "" ] || [ "$binary" -ne 1 ]; then
			printf 'missing deterministic binary arguments\n' >&2
			exit 64
		fi
		printf '%s,%s\n' "$seed" "$count" >> "$FAKE_RANDOM_ARGS_LOG"
		if [ "$seed" = "71" ]; then
			head -c "$count" /dev/zero | LC_ALL=C tr '\000' '\101'
		else
			head -c "$count" /dev/zero | LC_ALL=C tr '\000' '\102'
		fi
		exit $?
		;;
esac
exit 64
EOF

printf '#!%s\n' "$(type -P bash)" > "$FAKE_BIN/difz"
cat >> "$FAKE_BIN/difz" <<'EOF'
if [ "${1:-}" = "--about" ]; then
	printf 'difz 0.1.0 linux x86_64\n'
	exit 0
fi
exit 65
EOF

printf '#!%s\n' "$(type -P bash)" > "$FAKE_BIN/hyperfine"
cat >> "$FAKE_BIN/hyperfine" <<'EOF'
: > "$BM_BENCHMARK_MARKER"
kill -TERM "$PPID"
exit 66
EOF

chmod +x "$FAKE_BIN/zig" "$FAKE_BIN/random" "$FAKE_BIN/difz" "$FAKE_BIN/hyperfine"

printf "difz benchmark tests\n"
printf "====================\n"

assert_bad_generator_stops_before_benchmark() {
	local mode="$1"
	local expected_error="$2"
	local marker="$TEST_DIR/${mode}.benchmark-started"
	local stdout_file="$TEST_DIR/${mode}.stdout"
	local stderr_file="$TEST_DIR/${mode}.stderr"

	FAKE_RANDOM_MODE="$mode" \
	BM_BENCHMARK_MARKER="$marker" \
	BUILD_SCRIPT="$FAKE_BIN/zig" \
	DIFZ="$FAKE_BIN/difz" \
	RANDOM_BIN="$FAKE_BIN/random" \
	PATH="$FAKE_BIN:$PATH" \
		bash "$ROOT_DIR/bm" > "$stdout_file" 2> "$stderr_file"
	local rc=$?

	if [ "$rc" -ne 0 ] && [ ! -e "$marker" ] && grep -qF "$expected_error" "$stderr_file"; then
		pass "$mode random stops bm before benchmarking"
	else
		fail "$mode random stops bm before benchmarking" \
			"rc=$rc, benchmark_started=$([ -e "$marker" ] && printf yes || printf no), stderr=$(tr '\n' ' ' < "$stderr_file")"
	fi
}

assert_bad_generator_stops_before_benchmark fail "random failed while generating"
assert_bad_generator_stops_before_benchmark truncate "has 1 bytes; expected 1048576"

"$PINNED_RANDOM_BIN" --seed 71 -b -c 4097 \
	> "$TEST_DIR/pinned-random.bin" 2> "$TEST_DIR/pinned-random.stderr"
pinned_random_rc=$?
pinned_random_size=$(wc -c < "$TEST_DIR/pinned-random.bin" | tr -d ' ')
if [ "$pinned_random_rc" -eq 0 ] && [ "$pinned_random_size" -eq 4097 ]; then
	pass "pinned random emits the requested 4097 binary bytes"
else
	fail "pinned random emits the requested 4097 binary bytes" \
		"rc=$pinned_random_rc, size=$pinned_random_size, stderr=$(tr '\n' ' ' < "$TEST_DIR/pinned-random.stderr")"
fi

# Load only the fixture function so the positive contract stays fast and does
# not run the benchmark suite. The function remains exercised from bm itself.
eval "$(awk '/^generate_test_pair\(\)/,/^}/' "$ROOT_DIR/bm")"

info() { :; }
err() { printf '%s\n' "$1" >&2; }
human_bytes() { printf '%sB\n' "$1"; }

TMPDIR_BM="$TEST_DIR/exact"
RANDOM_BIN="$FAKE_BIN/random"
FAKE_RANDOM_ARGS_LOG="$TEST_DIR/random.args"
export FAKE_RANDOM_ARGS_LOG
mkdir -p "$TMPDIR_BM"
FAKE_RANDOM_MODE=exact
export FAKE_RANDOM_MODE
generate_test_pair exact 257 50 71 > "$TEST_DIR/exact.stdout" 2> "$TEST_DIR/exact.stderr"
exact_rc=$?
exact_a_size=$(wc -c < "$TMPDIR_BM/exact_a" | tr -d ' ')
exact_b_size=$(wc -c < "$TMPDIR_BM/exact_b" | tr -d ' ')
head -c 128 "$TMPDIR_BM/exact_a" > "$TEST_DIR/exact-a-prefix"
head -c 128 "$TMPDIR_BM/exact_b" > "$TEST_DIR/exact-b-prefix"
tail -c +129 "$TMPDIR_BM/exact_a" > "$TEST_DIR/exact-a-suffix"
tail -c +129 "$TMPDIR_BM/exact_b" > "$TEST_DIR/exact-b-suffix"

if [ "$exact_rc" -eq 0 ] && [ "$exact_a_size" -eq 257 ] && [ "$exact_b_size" -eq 257 ] &&
	[ "$(sed -n '1p' "$FAKE_RANDOM_ARGS_LOG")" = "71,257" ] &&
	[ "$(sed -n '2p' "$FAKE_RANDOM_ARGS_LOG")" = "10071,257" ] &&
	cmp -s "$TEST_DIR/exact-a-prefix" "$TEST_DIR/exact-b-prefix" &&
	! cmp -s "$TEST_DIR/exact-a-suffix" "$TEST_DIR/exact-b-suffix"; then
	pass "fixture generation uses the deterministic binary API and exact sizes"
else
	fail "fixture generation uses the deterministic binary API and exact sizes" \
		"rc=$exact_rc, A=$exact_a_size, B=$exact_b_size, stderr=$(tr '\n' ' ' < "$TEST_DIR/exact.stderr")"
fi

for function_name in has_date_ns now_ns time_cmd; do
	function_body=$(awk -v name="$function_name" '
		$0 ~ "^" name "\\(\\)" { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$ROOT_DIR/bm")
	eval "$function_body"
done

GNU_TIME_BIN="${GNU_TIME_BIN:-$(type -P time)}"
TMPDIR_BM="$TEST_DIR/timing"
mkdir -p "$TMPDIR_BM"
timing_result=$(time_cmd head -c 1048576 /dev/zero)
timing_fields=$(printf '%s\n' "$timing_result" | awk '{ print NF }')
timing_ms=$(printf '%s\n' "$timing_result" | cut -d' ' -f1)
timing_cpu_ms=$(printf '%s\n' "$timing_result" | cut -d' ' -f2)
timing_rss=$(printf '%s\n' "$timing_result" | cut -d' ' -f3)
timing_rc=$(printf '%s\n' "$timing_result" | cut -d' ' -f4)
if [ "$timing_fields" -eq 4 ] && [ "$timing_ms" -ge 0 ] 2>/dev/null &&
	[ "$timing_cpu_ms" -ge 0 ] 2>/dev/null && [ "$timing_rss" -gt 0 ] 2>/dev/null &&
	[ "$timing_rc" -eq 0 ] 2>/dev/null; then
	pass "timing captures wall and CPU milliseconds, peak RSS KiB, and exit status"
else
	fail "timing captures wall and CPU milliseconds, peak RSS KiB, and exit status" \
		"result=$timing_result"
fi

CORPUS_LIB="$ROOT_DIR/tests/benchmark/corpus.bash"
if [ ! -f "$CORPUS_LIB" ]; then
	fail "high-operation corpus generator is present" "$CORPUS_LIB is missing"
else
	# shellcheck source=corpus.bash
	source "$CORPUS_LIB"
	if type generate_interleaved_pair >/dev/null 2>&1 &&
		type install_real_elf_pair >/dev/null 2>&1 &&
		! type generate_binary_shape_pair >/dev/null 2>&1; then
		pass "high-operation corpus generator is present"
	else
		fail "high-operation corpus generator is present" \
			"real ELF installer is missing or manufactured binary generator remains"
	fi

	INTERLEAVED_DIR="$TEST_DIR/interleaved"
	mkdir -p "$INTERLEAVED_DIR"
	generate_interleaved_pair "$PINNED_RANDOM_BIN" "$INTERLEAVED_DIR" stress 1048576 9001 \
		> "$TEST_DIR/interleaved.stdout" 2> "$TEST_DIR/interleaved.stderr"
	interleaved_rc=$?
	interleaved_a_size=$(wc -c < "$INTERLEAVED_DIR/stress_a" | tr -d ' ')
	interleaved_b_size=$(wc -c < "$INTERLEAVED_DIR/stress_b" | tr -d ' ')
	"$PINNED_DIFZ" --no-progress "$INTERLEAVED_DIR/stress_a" "$INTERLEAVED_DIR/stress_b" \
		-o "$TEST_DIR/interleaved.diff" > "$TEST_DIR/interleaved-diff.stdout" 2> "$TEST_DIR/interleaved-diff.stderr"
	interleaved_diff_rc=$?
	"$PINNED_DIFZ" --inspect --truncate 0 "$TEST_DIR/interleaved.diff" \
		> "$TEST_DIR/interleaved.inspect" 2> "$TEST_DIR/interleaved-inspect.stderr"
	interleaved_inspect_rc=$?
	interleaved_ops=$(sed -n 's/^difz inspect: \([0-9][0-9]*\) ops,.*/\1/p' "$TEST_DIR/interleaved.inspect")
	if [ "$interleaved_rc" -eq 0 ] && [ "$interleaved_diff_rc" -eq 0 ] &&
		[ "$interleaved_inspect_rc" -eq 0 ] && [ "$interleaved_a_size" -eq 1048576 ] &&
		[ "$interleaved_b_size" -eq 1048576 ] && [ "${interleaved_ops:-0}" -ge 5000 ]; then
		pass "interleaved 1 MiB corpus yields at least 5,000 operations"
	else
		fail "interleaved 1 MiB corpus yields at least 5,000 operations" \
			"generate_rc=$interleaved_rc, diff_rc=$interleaved_diff_rc, inspect_rc=$interleaved_inspect_rc, A=$interleaved_a_size, B=$interleaved_b_size, ops=${interleaved_ops:-missing}"
	fi

	REAL_ELF_DIR="$TEST_DIR/real-elf"
	mkdir -p "$REAL_ELF_DIR"
	real_source="$PINNED_DIFZ"
	real_target=$(type -P true)
	install_real_elf_pair "$REAL_ELF_DIR" real_cli "$real_source" "$real_target" \
		github:example/real-cli \
		1111111111111111111111111111111111111111 \
		2222222222222222222222222222222222222222 \
		> "$TEST_DIR/real-elf.stdout" 2> "$TEST_DIR/real-elf.stderr"
	real_elf_rc=$?
	real_source_hash=$(sha256sum "$REAL_ELF_DIR/real_cli_a" 2>/dev/null | cut -d' ' -f1)
	real_target_hash=$(sha256sum "$REAL_ELF_DIR/real_cli_b" 2>/dev/null | cut -d' ' -f1)
	if [ "$real_elf_rc" -eq 0 ] && [ -x "$REAL_ELF_DIR/real_cli_a" ] &&
		[ -x "$REAL_ELF_DIR/real_cli_b" ] && [ "$real_source_hash" != "$real_target_hash" ] &&
		grep -qF 'source_revision=1111111111111111111111111111111111111111' \
			"$REAL_ELF_DIR/real_cli_provenance" &&
		grep -qF "source_sha256=$real_source_hash" "$REAL_ELF_DIR/real_cli_provenance" &&
		grep -qF "target_sha256=$real_target_hash" "$REAL_ELF_DIR/real_cli_provenance"; then
		pass "real ELF pair preserves executable inputs and immutable provenance"
	else
		fail "real ELF pair preserves executable inputs and immutable provenance" \
			"rc=$real_elf_rc, source_hash=${real_source_hash:-missing}, target_hash=${real_target_hash:-missing}, stderr=$(tr '\n' ' ' < "$TEST_DIR/real-elf.stderr")"
	fi

	LC_ALL=C tr '\000' '\001' < "$real_source" > "$TEST_DIR/manufactured-target"
	chmod +x "$TEST_DIR/manufactured-target"
	install_real_elf_pair "$REAL_ELF_DIR" manufactured "$real_source" \
		"$TEST_DIR/manufactured-target" github:example/real-cli \
		1111111111111111111111111111111111111111 \
		2222222222222222222222222222222222222222 \
		> "$TEST_DIR/manufactured.stdout" 2> "$TEST_DIR/manufactured.stderr"
	manufactured_rc=$?
	if [ "$manufactured_rc" -ne 0 ] && [ ! -e "$REAL_ELF_DIR/manufactured_a" ] &&
		[ ! -e "$REAL_ELF_DIR/manufactured_b" ]; then
		pass "real ELF pair rejects a byte-transformed executable-shaped target"
	else
		fail "real ELF pair rejects a byte-transformed executable-shaped target" \
			"rc=$manufactured_rc, stderr=$(tr '\n' ' ' < "$TEST_DIR/manufactured.stderr")"
	fi
fi

RESULTS_LIB="$ROOT_DIR/tests/benchmark/results.bash"
if [ ! -f "$RESULTS_LIB" ]; then
	fail "versioned benchmark results and apply-complexity gates are present" \
		"$RESULTS_LIB is missing"
else
	# shellcheck source=results.bash
	source "$RESULTS_LIB"
	RESULTS_LOG="$TEST_DIR/results-v3.csv"
	init_benchmark_log_v3 "$RESULTS_LOG"
	results_header=$(sed -n '1p' "$RESULTS_LOG")
	committed_results_header=$(sed -n '1p' "$ROOT_DIR/tests/benchmark/benchmark_log_v3.csv" 2>/dev/null)
	if [ "$results_header" = "$committed_results_header" ] &&
		echo "$results_header" | grep -q 'op_count' &&
		echo "$results_header" | grep -q 'difz_patch_peak_rss_kb' &&
		echo "$results_header" | grep -q 'difz_diff_cpu_ms' &&
		echo "$results_header" | grep -q 'host_arch' &&
		echo "$results_header" | grep -q 'source_revision' &&
		echo "$results_header" | grep -q 'target_sha256'; then
		pass "v3 benchmark log records resource use, platform, and corpus provenance"
	else
		fail "v3 benchmark log records resource use, platform, and corpus provenance" \
			"header=$results_header"
	fi

	if apply_complexity_regressed 100 10000 200 20000 25; then
		fail "apply-complexity gate normalizes by operation count" \
			"equal per-op work was reported as a regression"
	else
		pass "apply-complexity gate normalizes by operation count"
	fi

	if apply_complexity_regressed 100 10000 300 20000 25; then
		pass "apply-complexity gate catches a greater-than-25% regression"
	else
		fail "apply-complexity gate catches a greater-than-25% regression"
	fi
fi

v2_hash=$(sha256sum "$ROOT_DIR/tests/benchmark/benchmark_log_v2.csv" | cut -d' ' -f1)
if [ "$v2_hash" = 'baf0ef2dcd6f77904eb49cd5ed46c48c70de68027c120450aaaceddb90defe0c' ]; then
	pass "historical v2 benchmark log remains byte-for-byte unchanged"
else
	fail "historical v2 benchmark log remains byte-for-byte unchanged" "sha256=$v2_hash"
fi

if grep -qF 'historical shared-prefix corpus' "$ROOT_DIR/README.md" &&
	grep -qF 'benchmark_log_v3.csv' "$ROOT_DIR/README.md" &&
	grep -qF 'independently built Validate' "$ROOT_DIR/README.md" &&
	! grep -qF 'representative rebuilt-binary shape' "$ROOT_DIR/README.md" &&
	! grep -qF '**difz produces the smallest diffs** across all test cases.' "$ROOT_DIR/README.md"; then
	pass "README limits performance claims to the measured corpus"
else
	fail "README limits performance claims to the measured corpus"
fi

printf "\n%d tests, %d failures\n" "$TESTS" "$ERRORS"
exit "$ERRORS"
