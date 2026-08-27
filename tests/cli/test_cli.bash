#!/usr/bin/env bash
# CLI test suite for difz
# Tests the C CLI that dogfoods the difz FFI.
# Exit code = number of failed tests (0 = all pass).

set -u  # catch undefined variables; NO set -e (we test error paths)

ERRORS=0
TESTS=0
DIFZ="${DIFZ:-./zig-out/bin/difz}"
TEST_DIR="${TMPDIR:-/tmp}/difz_cli_tests_$$"

# ── Helpers ────────────────────────────────────────────────────────────

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

# ── Setup ──────────────────────────────────────────────────────────────

printf "difz CLI tests\n"
printf "===============\n"

# Build locally unless the enclosing Nix check supplied its already-built binary.
if [ "${DIFZ_PREBUILT:-0}" = "1" ]; then
	printf "\nUsing prebuilt difz...\n"
else
	printf "\nBuilding difz...\n"
	nix develop -c zig build -Doptimize=Debug 2>&1
	if [ $? -ne 0 ]; then
		printf "FATAL: build failed\n"
		exit 1
	fi
fi

if [ ! -x "$DIFZ" ]; then
	printf "FATAL: difz binary not found at %s\n" "$DIFZ"
	exit 1
fi

mkdir -p "$TEST_DIR"

# ── Test: --help ───────────────────────────────────────────────────────

printf "\n[--help / --about]\n"

HELP_OUT=$("$DIFZ" --help 2>/dev/null)
HELP_RC=$?
if [ $HELP_RC -eq 0 ]; then
	pass "--help exits 0"
else
	fail "--help exits 0" "got exit code $HELP_RC"
fi

if echo "$HELP_OUT" | grep -q "Usage:"; then
	pass "--help contains 'Usage:'"
else
	fail "--help contains 'Usage:'" "output: $HELP_OUT"
fi

if echo "$HELP_OUT" | grep -q -- "--patch"; then
	pass "--help mentions --patch"
else
	fail "--help mentions --patch" "output: $HELP_OUT"
fi

# -h should also work
H_OUT=$("$DIFZ" -h 2>/dev/null)
H_RC=$?
if [ $H_RC -eq 0 ]; then
	pass "-h exits 0"
else
	fail "-h exits 0" "got exit code $H_RC"
fi

# ── Test: --about ──────────────────────────────────────────────────────

ABOUT_OUT=$("$DIFZ" --about 2>/dev/null)
ABOUT_RC=$?
if [ $ABOUT_RC -eq 0 ]; then
	pass "--about exits 0"
else
	fail "--about exits 0" "got exit code $ABOUT_RC"
fi

if echo "$ABOUT_OUT" | grep -q "0.1.0"; then
	pass "--about contains version"
else
	fail "--about contains version" "output: $ABOUT_OUT"
fi

if echo "$ABOUT_OUT" | grep -qi "macos\|linux\|windows\|freebsd"; then
	pass "--about contains platform"
else
	fail "--about contains platform" "output: $ABOUT_OUT"
fi

if echo "$ABOUT_OUT" | grep -qi "aarch64\|x86_64\|arm\|x86"; then
	pass "--about contains architecture"
else
	fail "--about contains architecture" "output: $ABOUT_OUT"
fi

# ── Test: debug build detection ────────────────────────────────────────

printf "\n[Debug build detection]\n"

DEBUG_STDERR=$("$DIFZ" --about 2>&1 1>/dev/null)
if echo "$DEBUG_STDERR" | grep -q "DEBUG BUILD"; then
	pass "Debug build prints DEBUG BUILD to stderr"
else
	fail "Debug build prints DEBUG BUILD to stderr" "stderr: $DEBUG_STDERR"
fi

# ── Test: diff + patch round-trip ──────────────────────────────────────

printf "\n[Diff + Patch round-trip]\n"

# Create test files
printf 'the quick brown fox jumped over the lazy dog\n' > "$TEST_DIR/a.txt"
printf 'the quick red fox jumped over the lazy cat\n' > "$TEST_DIR/b.txt"

# Diff
DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/diff.bin" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "diff exits 0"
else
	fail "diff exits 0" "got exit code $DIFF_RC, stderr: $DIFF_STDERR"
fi

if [ -f "$TEST_DIR/diff.bin" ]; then
	DIFF_SIZE=$(wc -c < "$TEST_DIR/diff.bin" | tr -d ' ')
	if [ "$DIFF_SIZE" -gt 0 ]; then
		pass "diff output is non-empty ($DIFF_SIZE bytes)"
	else
		fail "diff output is non-empty" "size: 0"
	fi
else
	fail "diff output file created" "file not found"
fi

# Patch
PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/diff.bin" -o "$TEST_DIR/b_reconstructed.txt" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ]; then
	pass "patch exits 0"
else
	fail "patch exits 0" "got exit code $PATCH_RC, stderr: $PATCH_STDERR"
fi

# Compare
if diff -q "$TEST_DIR/b.txt" "$TEST_DIR/b_reconstructed.txt" >/dev/null 2>&1; then
	pass "round-trip: reconstructed matches original b"
else
	fail "round-trip: reconstructed matches original b" \
		"expected: $(cat "$TEST_DIR/b.txt"), got: $(cat "$TEST_DIR/b_reconstructed.txt")"
fi

# ── Test: round-trip with larger/binary data ───────────────────────────

printf "\n[Binary data round-trip]\n"

# Generate deterministic binary data.
dd if=/dev/zero bs=1 count=4096 of="$TEST_DIR/bin_a.dat" 2>/dev/null
# Copy and modify a few bytes
cp "$TEST_DIR/bin_a.dat" "$TEST_DIR/bin_b.dat"
printf '\xDE\xAD\xBE\xEF' | dd of="$TEST_DIR/bin_b.dat" bs=1 seek=100 conv=notrunc 2>/dev/null
printf '\xCA\xFE\xBA\xBE' | dd of="$TEST_DIR/bin_b.dat" bs=1 seek=2000 conv=notrunc 2>/dev/null

DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/bin_a.dat" "$TEST_DIR/bin_b.dat" -o "$TEST_DIR/bin_diff.dat" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "binary diff exits 0"
else
	fail "binary diff exits 0" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/bin_a.dat" "$TEST_DIR/bin_diff.dat" -o "$TEST_DIR/bin_b_out.dat" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ]; then
	pass "binary patch exits 0"
else
	fail "binary patch exits 0" "rc=$PATCH_RC, stderr: $PATCH_STDERR"
fi

if cmp -s "$TEST_DIR/bin_b.dat" "$TEST_DIR/bin_b_out.dat"; then
	pass "binary round-trip: reconstructed matches original"
else
	fail "binary round-trip: reconstructed matches original" "files differ"
fi

# ── Test: stdout output (default) ─────────────────────────────────────

printf "\n[Stdout/pipe output]\n"

# diff to stdout, capture to file (binary data may contain null bytes)
"$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" > "$TEST_DIR/stdout_diff.bin" 2>/dev/null
DIFF_RC=$?
STDOUT_SIZE=$(wc -c < "$TEST_DIR/stdout_diff.bin" | tr -d ' ')
if [ $DIFF_RC -eq 0 ] && [ "$STDOUT_SIZE" -gt 0 ]; then
	pass "diff to stdout works"
else
	fail "diff to stdout works" "rc=$DIFF_RC, output size=$STDOUT_SIZE"
fi

# ── Test: stdin input with - ──────────────────────────────────────────

printf "\n[Stdin input]\n"

# Pipe file_b via stdin using -
DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" - -o "$TEST_DIR/stdin_diff.bin" < "$TEST_DIR/b.txt" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "diff with stdin (-) exits 0"
else
	fail "diff with stdin (-) exits 0" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

# Verify the stdin-produced diff can reconstruct
PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/stdin_diff.bin" -o "$TEST_DIR/stdin_recon.txt" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ] && diff -q "$TEST_DIR/b.txt" "$TEST_DIR/stdin_recon.txt" >/dev/null 2>&1; then
	pass "round-trip via stdin works"
else
	fail "round-trip via stdin works" "rc=$PATCH_RC, stderr: $PATCH_STDERR"
fi

# Test @stdin alias
DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" @stdin -o "$TEST_DIR/atstdin_diff.bin" < "$TEST_DIR/b.txt" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "diff with @stdin exits 0"
else
	fail "diff with @stdin exits 0" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

# ── Test: explicit -o - for stdout ────────────────────────────────────

printf "\n[Explicit stdout with -o -]\n"

"$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o - > "$TEST_DIR/explicit_dash.bin" 2>/dev/null
EXPLICIT_RC=$?
EXPLICIT_SIZE=$(wc -c < "$TEST_DIR/explicit_dash.bin" | tr -d ' ')
if [ $EXPLICIT_RC -eq 0 ] && [ "$EXPLICIT_SIZE" -gt 0 ]; then
	pass "diff with -o - writes to stdout"
else
	fail "diff with -o - writes to stdout" "rc=$EXPLICIT_RC, size=$EXPLICIT_SIZE"
fi

"$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o @stdout > "$TEST_DIR/explicit_atstdout.bin" 2>/dev/null
EXPLICIT_RC2=$?
EXPLICIT_SIZE2=$(wc -c < "$TEST_DIR/explicit_atstdout.bin" | tr -d ' ')
if [ $EXPLICIT_RC2 -eq 0 ] && [ "$EXPLICIT_SIZE2" -gt 0 ]; then
	pass "diff with -o @stdout writes to stdout"
else
	fail "diff with -o @stdout writes to stdout" "rc=$EXPLICIT_RC2, size=$EXPLICIT_SIZE2"
fi

# ── Test: --seed option ───────────────────────────────────────────────

printf "\n[--seed option]\n"

SEED_HEX="0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"

DIFF_STDERR=$("$DIFZ" --no-progress --seed "$SEED_HEX" "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/seeded_diff.bin" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "--seed produces diff"
else
	fail "--seed produces diff" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

# Same seed should produce same output (deterministic)
DIFF_STDERR=$("$DIFZ" --no-progress --seed "$SEED_HEX" "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/seeded_diff2.bin" 2>&1)
if cmp -s "$TEST_DIR/seeded_diff.bin" "$TEST_DIR/seeded_diff2.bin"; then
	pass "same seed produces identical diff"
else
	fail "same seed produces identical diff" "diffs differ"
fi

# Round-trip with seeded diff
PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/seeded_diff.bin" -o "$TEST_DIR/seeded_recon.txt" 2>&1)
if diff -q "$TEST_DIR/b.txt" "$TEST_DIR/seeded_recon.txt" >/dev/null 2>&1; then
	pass "seeded diff round-trips correctly"
else
	fail "seeded diff round-trips correctly" "stderr: $PATCH_STDERR"
fi

# Bad seed (too short)
BAD_SEED_STDERR=$("$DIFZ" --no-progress --seed "0102" "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" 2>&1)
BAD_SEED_RC=$?
if [ $BAD_SEED_RC -ne 0 ]; then
	pass "bad seed (too short) returns error"
else
	fail "bad seed (too short) returns error" "expected non-zero exit"
fi

# Bad seed (non-hex chars)
BAD_SEED_STDERR=$("$DIFZ" --no-progress --seed "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg" "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" 2>&1)
BAD_SEED_RC=$?
if [ $BAD_SEED_RC -ne 0 ]; then
	pass "bad seed (non-hex) returns error"
else
	fail "bad seed (non-hex) returns error" "expected non-zero exit"
fi

# ── Test: --chunk-size option ─────────────────────────────────────────

printf "\n[--chunk-size option]\n"

DIFF_STDERR=$("$DIFZ" --no-progress --chunk-size 512 "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/cs_diff.bin" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "--chunk-size 512 accepted"
else
	fail "--chunk-size 512 accepted" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

# ── Test: paths with spaces ───────────────────────────────────────────

printf "\n[Paths with spaces]\n"

mkdir -p "$TEST_DIR/dir with spaces"
cp "$TEST_DIR/a.txt" "$TEST_DIR/dir with spaces/file a.txt"
cp "$TEST_DIR/b.txt" "$TEST_DIR/dir with spaces/file b.txt"

DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/dir with spaces/file a.txt" "$TEST_DIR/dir with spaces/file b.txt" -o "$TEST_DIR/dir with spaces/diff.bin" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "diff with spaces in path exits 0"
else
	fail "diff with spaces in path exits 0" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/dir with spaces/file a.txt" "$TEST_DIR/dir with spaces/diff.bin" -o "$TEST_DIR/dir with spaces/recon.txt" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ] && diff -q "$TEST_DIR/dir with spaces/file b.txt" "$TEST_DIR/dir with spaces/recon.txt" >/dev/null 2>&1; then
	pass "round-trip with spaces in path works"
else
	fail "round-trip with spaces in path works" "rc=$PATCH_RC"
fi

# ── Test: error cases ─────────────────────────────────────────────────

printf "\n[Error cases]\n"

# Missing file
MISSING_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/nonexistent_file.txt" "$TEST_DIR/b.txt" 2>&1)
MISSING_RC=$?
if [ $MISSING_RC -ne 0 ]; then
	pass "missing file returns error"
else
	fail "missing file returns error" "expected non-zero exit"
fi

if echo "$MISSING_STDERR" | grep -qi "cannot open"; then
	pass "missing file error message mentions 'cannot open'"
else
	fail "missing file error message mentions 'cannot open'" "stderr: $MISSING_STDERR"
fi

# Too few arguments
FEW_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" 2>&1)
FEW_RC=$?
if [ $FEW_RC -ne 0 ]; then
	pass "too few arguments returns error"
else
	fail "too few arguments returns error" "expected non-zero exit"
fi

# No arguments at all
NONE_STDERR=$("$DIFZ" 2>&1)
NONE_RC=$?
if [ $NONE_RC -ne 0 ]; then
	pass "no arguments returns error"
else
	fail "no arguments returns error" "expected non-zero exit"
fi

# Invalid diff file for patch mode
printf 'not a valid difz file at all' > "$TEST_DIR/bad_diff.bin"
BAD_PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/bad_diff.bin" 2>&1)
BAD_PATCH_RC=$?
if [ $BAD_PATCH_RC -ne 0 ]; then
	pass "patch with invalid diff returns error"
else
	fail "patch with invalid diff returns error" "expected non-zero exit"
fi

if echo "$BAD_PATCH_STDERR" | grep -qi "patch failed\|error"; then
	pass "patch error message is informative"
else
	fail "patch error message is informative" "stderr: $BAD_PATCH_STDERR"
fi

# Unknown option
UNKNOWN_STDERR=$("$DIFZ" --unknown-option 2>&1)
UNKNOWN_RC=$?
if [ $UNKNOWN_RC -ne 0 ]; then
	pass "unknown option returns error"
else
	fail "unknown option returns error" "expected non-zero exit"
fi

# Too many arguments
MANY_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" "$TEST_DIR/a.txt" 2>&1)
MANY_RC=$?
if [ $MANY_RC -ne 0 ]; then
	pass "too many arguments returns error"
else
	fail "too many arguments returns error" "expected non-zero exit"
fi

# ── Test: --patch mode explicitly ─────────────────────────────────────

printf "\n[--patch mode position independence]\n"

# --patch can appear before or after file args
# Before (already tested above in round-trip), test after
DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/pos_diff.bin" 2>&1)
PATCH_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/pos_diff.bin" --patch -o "$TEST_DIR/pos_recon.txt" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ] && diff -q "$TEST_DIR/b.txt" "$TEST_DIR/pos_recon.txt" >/dev/null 2>&1; then
	pass "--patch after file args works"
else
	fail "--patch after file args works" "rc=$PATCH_RC, stderr: $PATCH_STDERR"
fi

# ── Test: identical files ─────────────────────────────────────────────

printf "\n[Identical files]\n"

DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/a.txt" -o "$TEST_DIR/identical_diff.bin" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "diff of identical files exits 0"
else
	fail "diff of identical files exits 0" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

# Patch should reconstruct identical file
PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/identical_diff.bin" -o "$TEST_DIR/identical_recon.txt" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ] && diff -q "$TEST_DIR/a.txt" "$TEST_DIR/identical_recon.txt" >/dev/null 2>&1; then
	pass "identical files round-trip correctly"
else
	fail "identical files round-trip correctly" "rc=$PATCH_RC, stderr: $PATCH_STDERR"
fi

# ── Test: empty files ─────────────────────────────────────────────────

printf "\n[Empty files]\n"

: > "$TEST_DIR/empty.txt"

DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/empty.txt" "$TEST_DIR/a.txt" -o "$TEST_DIR/empty_diff.bin" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "diff with empty file_a exits 0"
else
	fail "diff with empty file_a exits 0" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/empty.txt" "$TEST_DIR/empty_diff.bin" -o "$TEST_DIR/empty_recon.txt" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ] && diff -q "$TEST_DIR/a.txt" "$TEST_DIR/empty_recon.txt" >/dev/null 2>&1; then
	pass "empty-to-nonempty round-trip works"
else
	fail "empty-to-nonempty round-trip works" "rc=$PATCH_RC, stderr: $PATCH_STDERR"
fi

# Both empty
DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/empty.txt" "$TEST_DIR/empty.txt" -o "$TEST_DIR/both_empty_diff.bin" 2>&1)
DIFF_RC=$?
if [ $DIFF_RC -eq 0 ]; then
	pass "diff of two empty files exits 0"
else
	fail "diff of two empty files exits 0" "rc=$DIFF_RC, stderr: $DIFF_STDERR"
fi

PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/empty.txt" "$TEST_DIR/both_empty_diff.bin" -o "$TEST_DIR/both_empty_recon.txt" 2>&1)
PATCH_RC=$?
if [ $PATCH_RC -eq 0 ]; then
	RECON_SIZE=$(wc -c < "$TEST_DIR/both_empty_recon.txt" | tr -d ' ')
	if [ "$RECON_SIZE" -eq 0 ]; then
		pass "both-empty round-trip produces empty file"
	else
		fail "both-empty round-trip produces empty file" "reconstructed size: $RECON_SIZE"
	fi
else
	fail "both-empty round-trip produces empty file" "rc=$PATCH_RC, stderr: $PATCH_STDERR"
fi

# ── Test: stderr output cleanliness ───────────────────────────────────

printf "\n[Stderr cleanliness]\n"

# With --no-progress, stderr should only contain DEBUG BUILD (since we built debug)
CLEAN_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o /dev/null 2>&1)
# Remove the expected DEBUG BUILD line
CLEAN_STDERR_FILTERED=$(echo "$CLEAN_STDERR" | grep -v "^DEBUG BUILD$" | grep -v "^$")
if [ -z "$CLEAN_STDERR_FILTERED" ]; then
	pass "stderr is clean with --no-progress (no unexpected output)"
else
	fail "stderr is clean with --no-progress" "unexpected stderr: $CLEAN_STDERR_FILTERED"
fi

# ── Summary ────────────────────────────────────────────────────────────

printf "\n===============\n"
printf "%d tests, %d failed\n" "$TESTS" "$ERRORS"

exit "$ERRORS"
