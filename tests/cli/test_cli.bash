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
DIFZ_DIR="$(cd "$(dirname "$DIFZ")" && pwd)"
DIFZ="$DIFZ_DIR/$(basename "$DIFZ")"

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

# Compare through an external cryptographic oracle rather than difz internals.
TARGET_SHA256=$(sha256sum "$TEST_DIR/b.txt" | cut -d ' ' -f 1)
RECONSTRUCTED_SHA256=$(sha256sum "$TEST_DIR/b_reconstructed.txt" | cut -d ' ' -f 1)
if [ "$TARGET_SHA256" = "$RECONSTRUCTED_SHA256" ]; then
	pass "round-trip: external SHA-256 matches original b"
else
	fail "round-trip: external SHA-256 matches original b" \
		"expected: $TARGET_SHA256, got: $RECONSTRUCTED_SHA256"
fi

{
	printf 'X'
	tail -c +2 "$TEST_DIR/a.txt"
} > "$TEST_DIR/wrong_same_size.txt"
if [ "$(wc -c < "$TEST_DIR/a.txt")" = "$(wc -c < "$TEST_DIR/wrong_same_size.txt")" ] &&
	! cmp -s "$TEST_DIR/a.txt" "$TEST_DIR/wrong_same_size.txt"; then
	pass "wrong-source fixture has equal length and different bytes"
else
	fail "wrong-source fixture has equal length and different bytes"
fi
WRONG_FILE_STDERR=$("$DIFZ" --patch --no-progress \
	"$TEST_DIR/wrong_same_size.txt" "$TEST_DIR/diff.bin" -o "$TEST_DIR/wrong_file_output.txt" 2>&1)
WRONG_FILE_RC=$?
if [ $WRONG_FILE_RC -ne 0 ] && [ ! -e "$TEST_DIR/wrong_file_output.txt" ]; then
	pass "wrong same-sized file source creates no output"
else
	fail "wrong same-sized file source creates no output" "rc=$WRONG_FILE_RC, stderr: $WRONG_FILE_STDERR"
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

# ── Test: output I/O failures must not report success ─────────────────

printf "\n[Output I/O failures]\n"

if [ -e /dev/full ]; then
	FULL_ERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o /dev/full 2>&1)
	FULL_RC=$?
	FULL_ERR_FILTERED=$(printf '%s\n' "$FULL_ERR" | grep -v "^DEBUG BUILD$" | grep -v "^$")
	if [ $FULL_RC -ne 0 ] && [ -n "$FULL_ERR_FILTERED" ]; then
		pass "named /dev/full output fails closed"
	else
		fail "named /dev/full output fails closed" "rc=$FULL_RC, stderr: $FULL_ERR"
	fi

	"$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" > /dev/full 2>"$TEST_DIR/stdout_full.err"
	STDOUT_FULL_RC=$?
	STDOUT_FULL_ERR=$(cat "$TEST_DIR/stdout_full.err")
	STDOUT_FULL_FILTERED=$(printf '%s\n' "$STDOUT_FULL_ERR" | grep -v "^DEBUG BUILD$" | grep -v "^$")
	if [ $STDOUT_FULL_RC -ne 0 ] && [ -n "$STDOUT_FULL_FILTERED" ]; then
		pass "stdout redirected to /dev/full fails closed"
	else
		fail "stdout redirected to /dev/full fails closed" "rc=$STDOUT_FULL_RC, stderr: $STDOUT_FULL_ERR"
	fi
else
	pass "named /dev/full output fails closed (skipped: no /dev/full)"
	pass "stdout redirected to /dev/full fails closed (skipped: no /dev/full)"
fi

# ── Test: @stderr stream aliases ──────────────────────────────────────

printf "\n[@stderr stream aliases]\n"

mkdir -p "$TEST_DIR/atstderr_work"
cp "$TEST_DIR/a.txt" "$TEST_DIR/atstderr_work/a.txt"
cp "$TEST_DIR/b.txt" "$TEST_DIR/atstderr_work/b.txt"
(
	cd "$TEST_DIR/atstderr_work"
	"$DIFZ" --no-progress a.txt b.txt -o @stderr >file_atstderr_out.bin 2>file_atstderr_err.bin
	echo $? > file_atstderr_rc.txt
	if [ -e @stderr ]; then echo yes; else echo no; fi > file_atstderr_literal.txt
)
FILE_ATSTDERR_RC=$(cat "$TEST_DIR/atstderr_work/file_atstderr_rc.txt")
FILE_ATSTDERR_LITERAL=$(cat "$TEST_DIR/atstderr_work/file_atstderr_literal.txt")
FILE_ATSTDERR_ERR_SIZE=$(wc -c < "$TEST_DIR/atstderr_work/file_atstderr_err.bin" | tr -d ' ')
if [ "$FILE_ATSTDERR_RC" = "0" ] && [ "$FILE_ATSTDERR_LITERAL" = "no" ] && [ "$FILE_ATSTDERR_ERR_SIZE" -gt 0 ]; then
	pass "file -o @stderr writes the patch to stderr"
else
	fail "file -o @stderr writes the patch to stderr" \
		"rc=$FILE_ATSTDERR_RC literal=$FILE_ATSTDERR_LITERAL stderr_bytes=$FILE_ATSTDERR_ERR_SIZE"
fi

mkdir -p "$TEST_DIR/atstderr_work/empty_a" "$TEST_DIR/atstderr_work/empty_b"
(
	cd "$TEST_DIR/atstderr_work"
	"$DIFZ" --no-progress empty_a empty_b -o @stderr >tree_atstderr_out.bin 2>tree_atstderr_err.bin
	echo $? > tree_atstderr_rc.txt
	if [ -e @stderr ]; then echo yes; else echo no; fi > tree_atstderr_literal.txt
)
TREE_ATSTDERR_RC=$(cat "$TEST_DIR/atstderr_work/tree_atstderr_rc.txt")
TREE_ATSTDERR_LITERAL=$(cat "$TEST_DIR/atstderr_work/tree_atstderr_literal.txt")
TREE_ATSTDERR_ERR_SIZE=$(wc -c < "$TEST_DIR/atstderr_work/tree_atstderr_err.bin" | tr -d ' ')
TREE_ATSTDERR_ERR_FILTERED_SIZE=$(grep -a -v "^DEBUG BUILD$" "$TEST_DIR/atstderr_work/tree_atstderr_err.bin" | grep -a -v "^$" | wc -c | tr -d ' ')
if [ "$TREE_ATSTDERR_RC" = "0" ] && [ "$TREE_ATSTDERR_LITERAL" = "no" ] && [ "$TREE_ATSTDERR_ERR_FILTERED_SIZE" -gt 0 ]; then
	pass "directory -o @stderr writes the patch to stderr"
else
	fail "directory -o @stderr writes the patch to stderr" \
		"rc=$TREE_ATSTDERR_RC literal=$TREE_ATSTDERR_LITERAL stderr_bytes=$TREE_ATSTDERR_ERR_SIZE filtered=$TREE_ATSTDERR_ERR_FILTERED_SIZE"
fi

# ── Test: repeated diffs are byte-identical ───────────────────────────

printf "\n[Deterministic file diff]\n"

DIFF_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/det_diff.bin" 2>&1)
DIFF_RC=$?
DIFF2_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/det_diff2.bin" 2>&1)
DIFF2_RC=$?
if [ $DIFF_RC -eq 0 ] && [ $DIFF2_RC -eq 0 ] && cmp -s "$TEST_DIR/det_diff.bin" "$TEST_DIR/det_diff2.bin"; then
	pass "repeated file diffs are byte-identical"
else
	fail "repeated file diffs are byte-identical" "rc=$DIFF_RC/$DIFF2_RC stderr=$DIFF_STDERR $DIFF2_STDERR"
fi

PATCH_STDERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/det_diff.bin" -o "$TEST_DIR/det_recon.txt" 2>&1)
if diff -q "$TEST_DIR/b.txt" "$TEST_DIR/det_recon.txt" >/dev/null 2>&1; then
	pass "file diff round-trips"
else
	fail "file diff round-trips" "stderr: $PATCH_STDERR"
fi

# ── Test: retired CDC and compressor flags ────────────────────────────

printf "\n[Retired flags]\n"

retired_flag() {
	local flag="$1"
	local err rc
	err=$("$DIFZ" --no-progress "$flag" "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/retired.patch" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ] && echo "$err" | grep -q "unknown option" && [ ! -e "$TEST_DIR/retired.patch" ]; then
		pass "retired flag $flag is an unknown option"
	else
		fail "retired flag $flag is an unknown option" "rc=$rc stderr=$err"
	fi
}

retired_flag --seed
retired_flag --chunk-size
retired_flag --compress
retired_flag --truncate
retired_flag --hexlike

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

# ── Test: directory diff + staged patch ───────────────────────────────

printf "\n[Directory diff + staged patch]\n"

mkdir -p "$TEST_DIR/empty source" "$TEST_DIR/empty target"
EMPTY_TREE_ERR=$("$DIFZ" --no-progress "$TEST_DIR/empty source" "$TEST_DIR/empty target" -o "$TEST_DIR/empty-tree.patch" 2>&1)
EMPTY_TREE_RC=$?
EMPTY_TREE_VERSION=$(od -An -v -tx1 -j8 -N4 "$TEST_DIR/empty-tree.patch" 2>/dev/null | tr -d '[:space:]')
if [ "$EMPTY_TREE_RC" = 0 ] && [ "$EMPTY_TREE_VERSION" = 02000200 ]; then
	pass "empty directory patch declares format and reader v2"
else
	fail "empty directory patch declares format and reader v2" "rc=$EMPTY_TREE_RC, version=$EMPTY_TREE_VERSION, stderr=$EMPTY_TREE_ERR"
fi

# A valid empty-tree v1 patch captured from the writer at b2144d1.
printf '%b' \
	'\x44\x49\x46\x5a\x54\x52\x45\x45\x01\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xbe\x92\x5e\x35\x99\xb9\x13\x8c' \
	'\xfe\xdb\x5e\x68\xd9\xac\xc6\x94\x7f\x13\x9a\x0b\x03\x04\xc0\x96\xf2\xcc\xa1\x0f\xa7\xa6\xb6\xc2\xbe\x92\x5e\x35\x99\xb9\x13\x8c' \
	'\xfe\xdb\x5e\x68\xd9\xac\xc6\x94\x7f\x13\x9a\x0b\x03\x04\xc0\x96\xf2\xcc\xa1\x0f\xa7\xa6\xb6\xc2\xb4\xec\xd4\x67\x38\x1f\x81\xb4' \
	'\xef\x72\x31\x8f\x13\xe5\xdb\x47\x0e\xc0\x3b\x33\x34\xa9\x70\x0b\x77\x4c\xb6\x90\xf6\xbe\x08\x37' > "$TEST_DIR/legacy-tree.patch"
LEGACY_TREE_ERR=$("$DIFZ" --patch --no-progress "$TEST_DIR/empty source" "$TEST_DIR/legacy-tree.patch" -o "$TEST_DIR/legacy output" 2>&1)
LEGACY_TREE_RC=$?
if [ "$LEGACY_TREE_RC" -ne 0 ] && [ ! -e "$TEST_DIR/legacy output" ]; then
	pass "legacy v1 tree patch is rejected without publishing output"
else
	fail "legacy v1 tree patch is rejected without publishing output" "rc=$LEGACY_TREE_RC, stderr=$LEGACY_TREE_ERR"
fi

mkdir -p "$TEST_DIR/tree source/bin" "$TEST_DIR/tree target/bin" "$TEST_DIR/tree target/empty"
printf 'old application with shared suffix\n' > "$TEST_DIR/tree source/bin/app"
printf 'delete me\n' > "$TEST_DIR/tree source/deleted.txt"
printf 'unchanged\n' > "$TEST_DIR/tree source/same.txt"
printf 'new application with shared suffix\n' > "$TEST_DIR/tree target/bin/app"
printf 'new file\x00bytes\n' > "$TEST_DIR/tree target/new.bin"
printf 'unchanged\n' > "$TEST_DIR/tree target/same.txt"
ln -s bin "$TEST_DIR/tree target/current"
chmod 711 "$TEST_DIR/tree target/empty"

TREE_DIFF_STDERR=$("$DIFZ" --no-progress \
	"$TEST_DIR/tree source" "$TEST_DIR/tree target" -o "$TEST_DIR/tree.patch" 2>&1)
TREE_DIFF_RC=$?
if [ $TREE_DIFF_RC -eq 0 ] && [ -s "$TEST_DIR/tree.patch" ]; then
	pass "directory diff creates a nonempty patch"
else
	fail "directory diff creates a nonempty patch" "rc=$TREE_DIFF_RC, stderr: $TREE_DIFF_STDERR"
fi

TREE_MAGIC=$(dd if="$TEST_DIR/tree.patch" bs=1 count=8 2>/dev/null)
if [ "$TREE_MAGIC" = "DIFZTREE" ]; then
	pass "directory patch uses DIFZTREE magic"
else
	fail "directory patch uses DIFZTREE magic" "magic: $TREE_MAGIC"
fi

TREE_DIFF_2_STDERR=$("$DIFZ" --no-progress \
	"$TEST_DIR/tree source" "$TEST_DIR/tree target" -o "$TEST_DIR/tree-2.patch" 2>&1)
TREE_DIFF_2_RC=$?
if [ $TREE_DIFF_2_RC -eq 0 ] && cmp -s "$TEST_DIR/tree.patch" "$TEST_DIR/tree-2.patch"; then
	pass "directory encoding is deterministic"
else
	fail "directory encoding is deterministic" "rc=$TREE_DIFF_2_RC, stderr: $TREE_DIFF_2_STDERR"
fi

printf 'preserve patch output\n' > "$TEST_DIR/existing.patch"
EXISTING_PATCH_STDERR=$("$DIFZ" --no-progress \
	"$TEST_DIR/tree source" "$TEST_DIR/tree target" -o "$TEST_DIR/existing.patch" 2>&1)
EXISTING_PATCH_RC=$?
if [ $EXISTING_PATCH_RC -ne 0 ] && [ "$(cat "$TEST_DIR/existing.patch")" = "preserve patch output" ]; then
	pass "preexisting directory patch file is preserved"
else
	fail "preexisting directory patch file is preserved" "rc=$EXISTING_PATCH_RC, stderr: $EXISTING_PATCH_STDERR"
fi

TREE_PATCH_STDERR=$("$DIFZ" --patch --no-progress \
	"$TEST_DIR/tree source" "$TEST_DIR/tree.patch" -o "$TEST_DIR/tree output" 2>&1)
TREE_PATCH_RC=$?
if [ $TREE_PATCH_RC -eq 0 ]; then
	pass "directory patch exits 0"
else
	fail "directory patch exits 0" "rc=$TREE_PATCH_RC, stderr: $TREE_PATCH_STDERR"
fi

if diff -r --no-dereference "$TEST_DIR/tree target" "$TEST_DIR/tree output" >/dev/null 2>&1; then
	pass "independent recursive comparison matches the target tree"
else
	fail "independent recursive comparison matches the target tree" \
		"$(diff -r --no-dereference "$TEST_DIR/tree target" "$TEST_DIR/tree output" 2>&1)"
fi

TARGET_EMPTY_MODE=$(stat -c '%a' "$TEST_DIR/tree target/empty")
OUTPUT_EMPTY_MODE=$(stat -c '%a' "$TEST_DIR/tree output/empty")
if [ "$TARGET_EMPTY_MODE" = "$OUTPUT_EMPTY_MODE" ]; then
	pass "directory mode round-trips"
else
	fail "directory mode round-trips" "expected $TARGET_EMPTY_MODE, got $OUTPUT_EMPTY_MODE"
fi

if [ -f "$TEST_DIR/tree source/deleted.txt" ]; then
	pass "directory patch leaves its source unchanged"
else
	fail "directory patch leaves its source unchanged" "source deletion was mutated"
fi

cp -R "$TEST_DIR/tree source" "$TEST_DIR/tree wrong"
printf 'BAD application with shared suffix\n' > "$TEST_DIR/tree wrong/bin/app"
WRONG_TREE_STDERR=$("$DIFZ" --patch --no-progress \
	"$TEST_DIR/tree wrong" "$TEST_DIR/tree.patch" -o "$TEST_DIR/wrong output" 2>&1)
WRONG_TREE_RC=$?
if [ $WRONG_TREE_RC -ne 0 ] && [ ! -e "$TEST_DIR/wrong output" ]; then
	pass "wrong directory source creates no output"
else
	fail "wrong directory source creates no output" "rc=$WRONG_TREE_RC, stderr: $WRONG_TREE_STDERR"
fi

mkdir "$TEST_DIR/existing tree output"
printf 'preserve\n' > "$TEST_DIR/existing tree output/sentinel"
EXISTING_TREE_STDERR=$("$DIFZ" --patch --no-progress \
	"$TEST_DIR/tree source" "$TEST_DIR/tree.patch" -o "$TEST_DIR/existing tree output" 2>&1)
EXISTING_TREE_RC=$?
if [ $EXISTING_TREE_RC -ne 0 ] && [ "$(cat "$TEST_DIR/existing tree output/sentinel")" = "preserve" ]; then
	pass "preexisting directory output is preserved"
else
	fail "preexisting directory output is preserved" "rc=$EXISTING_TREE_RC, stderr: $EXISTING_TREE_STDERR"
fi

MISMATCH_STDERR=$("$DIFZ" --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/tree target" -o "$TEST_DIR/mismatch.patch" 2>&1)
MISMATCH_RC=$?
if [ $MISMATCH_RC -ne 0 ] && [ ! -e "$TEST_DIR/mismatch.patch" ]; then
	pass "file-to-directory diff is rejected"
else
	fail "file-to-directory diff is rejected" "rc=$MISMATCH_RC, stderr: $MISMATCH_STDERR"
fi

mkdir -p "$TEST_DIR/filter source/kept" "$TEST_DIR/filter target/kept"
printf 'old\n' > "$TEST_DIR/filter source/kept/data.txt"
printf 'old cache\n' > "$TEST_DIR/filter source/kept/cache.tmp"
printf 'new\n' > "$TEST_DIR/filter target/kept/data.txt"
printf 'new cache\n' > "$TEST_DIR/filter target/kept/cache.tmp"
FILTER_DIFF_STDERR=$("$DIFZ" --no-progress --allow 'kept/**' --deny '**/*.tmp' \
	"$TEST_DIR/filter source" "$TEST_DIR/filter target" -o "$TEST_DIR/filter.patch" 2>&1)
FILTER_DIFF_RC=$?
FILTER_PATCH_STDERR=$("$DIFZ" --patch --no-progress \
	"$TEST_DIR/filter source" "$TEST_DIR/filter.patch" -o "$TEST_DIR/filter output" 2>&1)
FILTER_PATCH_RC=$?
if [ $FILTER_DIFF_RC -eq 0 ] && [ $FILTER_PATCH_RC -eq 0 ] \
	&& [ "$(cat "$TEST_DIR/filter output/kept/data.txt")" = "new" ] \
	&& [ ! -e "$TEST_DIR/filter output/kept/cache.tmp" ]; then
	pass "ordered allow and deny rules scope directory output"
else
	fail "ordered allow and deny rules scope directory output" \
		"diff rc=$FILTER_DIFF_RC, patch rc=$FILTER_PATCH_RC, diff stderr: $FILTER_DIFF_STDERR, patch stderr: $FILTER_PATCH_STDERR"
fi

STAGE_LEFTOVERS=$(find "$TEST_DIR" -name '*.difz-stage-*' -print)
if [ -z "$STAGE_LEFTOVERS" ]; then
	pass "directory failures leave no owned staging paths"
else
	fail "directory failures leave no owned staging paths" "paths: $STAGE_LEFTOVERS"
fi

# ── Test: --simple / --no-ansi suppress escape codes ──────────────────

printf "\n[--simple / --no-ansi]\n"

SIMPLE_ERR=$("$DIFZ" --simple --no-progress "$TEST_DIR/a.txt" "$TEST_DIR/b.txt" -o "$TEST_DIR/simple.patch" 2>&1 >/dev/null)
SIMPLE_RC=$?
if [ $SIMPLE_RC -eq 0 ] && printf '%s' "$SIMPLE_ERR" | grep -a -q $'\033'; then
	fail "--simple stderr has no ANSI escapes" "stderr contained ESC"
elif [ $SIMPLE_RC -eq 0 ]; then
	pass "--simple stderr has no ANSI escapes"
else
	fail "--simple stderr has no ANSI escapes" "rc=$SIMPLE_RC, stderr: $SIMPLE_ERR"
fi

if command -v script >/dev/null 2>&1; then
	script -q -e -c "$DIFZ --simple $TEST_DIR/a.txt $TEST_DIR/b.txt -o $TEST_DIR/simple_pty.patch" \
		"$TEST_DIR/simple.pty" >/dev/null 2>&1
	if grep -a -q $'\033' "$TEST_DIR/simple.pty"; then
		fail "--simple under a PTY emits no ANSI" "captured ESC in $TEST_DIR/simple.pty"
	else
		pass "--simple under a PTY emits no ANSI"
	fi
else
	pass "--simple under a PTY emits no ANSI (skipped: no script)"
fi

# ── Test: resource ceilings ───────────────────────────────────────────

printf "\n[Resource ceilings]\n"

CEIL_A="$TEST_DIR/ceil_a.bin"
CEIL_B="$TEST_DIR/ceil_b.bin"
# Two 8 KiB files that share a long prefix so a 100% ratio can still succeed,
# while a 1% ratio and a 16-byte cap still fail on ZDIF header overhead.
dd if=/dev/zero bs=8192 count=1 2>/dev/null | tr '\0' 'A' > "$CEIL_A"
cp "$CEIL_A" "$CEIL_B"
printf 'B' | dd of="$CEIL_B" bs=1 seek=8191 conv=notrunc 2>/dev/null

CEIL_OK_ERR=$("$DIFZ" --no-progress --max-output-bytes 1000000 "$CEIL_A" "$CEIL_B" -o "$TEST_DIR/ceil_ok.difz" 2>&1)
CEIL_OK_RC=$?
if [ $CEIL_OK_RC -eq 0 ] && [ -s "$TEST_DIR/ceil_ok.difz" ]; then
	pass "--max-output-bytes 1000000 allows an 8 KiB dissimilar patch"
else
	fail "--max-output-bytes 1000000 allows an 8 KiB dissimilar patch" "rc=$CEIL_OK_RC stderr=$CEIL_OK_ERR"
fi

CEIL_FAIL_ERR=$("$DIFZ" --no-progress --max-output-bytes 16 "$CEIL_A" "$CEIL_B" -o "$TEST_DIR/ceil_fail.difz" 2>&1)
CEIL_FAIL_RC=$?
if [ $CEIL_FAIL_RC -ne 0 ] && [ ! -e "$TEST_DIR/ceil_fail.difz" ]; then
	pass "--max-output-bytes 16 rejects an oversized patch with no output file"
else
	fail "--max-output-bytes 16 rejects an oversized patch with no output file" "rc=$CEIL_FAIL_RC stderr=$CEIL_FAIL_ERR"
fi
if echo "$CEIL_FAIL_ERR" | grep -q "resource limit"; then
	pass "--max-output-bytes failure mentions resource limit"
else
	fail "--max-output-bytes failure mentions resource limit" "stderr=$CEIL_FAIL_ERR"
fi

RATIO_FAIL_ERR=$("$DIFZ" --no-progress --max-output-ratio 1 "$CEIL_A" "$CEIL_B" -o "$TEST_DIR/ratio_fail.difz" 2>&1)
RATIO_FAIL_RC=$?
if [ $RATIO_FAIL_RC -ne 0 ] && [ ! -e "$TEST_DIR/ratio_fail.difz" ]; then
	pass "--max-output-ratio 1 rejects a patch larger than 1% of the target"
else
	fail "--max-output-ratio 1 rejects a patch larger than 1% of the target" "rc=$RATIO_FAIL_RC stderr=$RATIO_FAIL_ERR"
fi

RATIO_OK_ERR=$("$DIFZ" --no-progress --max-output-ratio 100 "$CEIL_A" "$CEIL_B" -o "$TEST_DIR/ratio_ok.difz" 2>&1)
RATIO_OK_RC=$?
if [ $RATIO_OK_RC -eq 0 ] && [ -s "$TEST_DIR/ratio_ok.difz" ]; then
	pass "--max-output-ratio 100 allows a patch at most the target size"
else
	fail "--max-output-ratio 100 allows a patch at most the target size" "rc=$RATIO_OK_RC stderr=$RATIO_OK_ERR"
fi

if [ -s "$TEST_DIR/ceil_ok.difz" ]; then
	PATCH_LIM_ERR=$("$DIFZ" --patch --no-progress --max-output-bytes 16 \
		"$CEIL_A" "$TEST_DIR/ceil_ok.difz" -o "$TEST_DIR/ceil_recon.bin" 2>&1)
	PATCH_LIM_RC=$?
	if [ $PATCH_LIM_RC -ne 0 ] && [ ! -e "$TEST_DIR/ceil_recon.bin" ]; then
		pass "--max-output-bytes 16 rejects a reconstructed target larger than 16 bytes"
	else
		fail "--max-output-bytes 16 rejects a reconstructed target larger than 16 bytes" "rc=$PATCH_LIM_RC stderr=$PATCH_LIM_ERR"
	fi
	PATCH_OK_ERR=$("$DIFZ" --patch --no-progress --max-output-bytes 1000000 \
		"$CEIL_A" "$TEST_DIR/ceil_ok.difz" -o "$TEST_DIR/ceil_recon_ok.bin" 2>&1)
	PATCH_OK_RC=$?
	if [ $PATCH_OK_RC -eq 0 ] && cmp -s "$CEIL_B" "$TEST_DIR/ceil_recon_ok.bin"; then
		pass "--max-output-bytes 1000000 allows reconstructing the 8 KiB target"
	else
		fail "--max-output-bytes 1000000 allows reconstructing the 8 KiB target" "rc=$PATCH_OK_RC stderr=$PATCH_OK_ERR"
	fi
else
	fail "--max-output-bytes 16 rejects a reconstructed target larger than 16 bytes" "no successful patch to apply"
	fail "--max-output-bytes 1000000 allows reconstructing the 8 KiB target" "no successful patch to apply"
fi

RSS_ERR=$("$DIFZ" --no-progress --max-rss-bytes 4096 \
	"$CEIL_A" "$CEIL_B" -o "$TEST_DIR/rss_fail.difz" 2>&1)
RSS_RC=$?
if [ $RSS_RC -ne 0 ]; then
	pass "--max-rss-bytes 4096 fails closed"
else
	fail "--max-rss-bytes 4096 fails closed" "rc=$RSS_RC stderr=$RSS_ERR"
fi

RSS_OK_ERR=$("$DIFZ" --no-progress --max-rss-bytes 8589934592 \
	"$CEIL_A" "$CEIL_B" -o "$TEST_DIR/rss_ok.difz" 2>&1)
RSS_OK_RC=$?
if [ $RSS_OK_RC -eq 0 ] && [ -s "$TEST_DIR/rss_ok.difz" ]; then
	pass "--max-rss-bytes 8GiB allows a tiny create"
else
	fail "--max-rss-bytes 8GiB allows a tiny create" "rc=$RSS_OK_RC stderr=$RSS_OK_ERR"
fi

WALL_ERR=$("$DIFZ" --no-progress --max-wall-ms 1 \
	"$CEIL_A" "$CEIL_B" -o "$TEST_DIR/wall_tiny.difz" 2>&1)
WALL_RC=$?
# 8 KiB may finish under 1ms; a 1ms ceiling must still be accepted as a flag.
# Force a miss with a zero-ms rejected parse, and a huge-ms success.
WALL_BAD=$("$DIFZ" --no-progress --max-wall-ms 0 "$CEIL_A" "$CEIL_B" -o "$TEST_DIR/wall_zero.difz" 2>&1)
WALL_BAD_RC=$?
if [ $WALL_BAD_RC -ne 0 ] && echo "$WALL_BAD" | grep -qi 'max-wall'; then
	pass "--max-wall-ms 0 is rejected"
else
	fail "--max-wall-ms 0 is rejected" "rc=$WALL_BAD_RC stderr=$WALL_BAD"
fi
WALL_OK=$("$DIFZ" --no-progress --max-wall-ms 60000 \
	"$CEIL_A" "$CEIL_B" -o "$TEST_DIR/wall_ok.difz" 2>&1)
WALL_OK_RC=$?
if [ $WALL_OK_RC -eq 0 ]; then
	pass "--max-wall-ms 60000 allows a tiny create"
else
	fail "--max-wall-ms 60000 allows a tiny create" "rc=$WALL_OK_RC stderr=$WALL_OK"
fi

if echo "$HELP_OUT" | grep -q -- "--max-output-bytes"; then
	pass "--help mentions --max-output-bytes"
else
	fail "--help mentions --max-output-bytes" "output: $HELP_OUT"
fi

# ── Test: i18n prepare-phase ──────────────────────────────────────────

printf "\n[i18n prepare]\n"

LANG_EN=$("$DIFZ" --lang en --help 2>/dev/null)
if echo "$LANG_EN" | grep -q "Usage:"; then
	pass "--lang en still prints English help"
else
	fail "--lang en still prints English help" "output: $LANG_EN"
fi

LANG_DE_ERR=$("$DIFZ" --lang de --about 2>&1 >/dev/null)
if echo "$LANG_DE_ERR" | grep -q "WARN: i18n missing-locale de"; then
	pass "--lang de warns that the German catalog is missing (prepare phase)"
else
	fail "--lang de warns that the German catalog is missing (prepare phase)" "stderr=$LANG_DE_ERR"
fi

HILFE_ERR=$("$DIFZ" --hilfe 2>&1 >/dev/null)
HILFE_OUT=$("$DIFZ" --hilfe 2>/dev/null)
if echo "$HILFE_ERR" | grep -q "WARN: i18n missing-locale de" && echo "$HILFE_OUT" | grep -q "Usage:"; then
	pass "--hilfe infers German, warns, and still prints help"
else
	fail "--hilfe infers German, warns, and still prints help" "stderr=$HILFE_ERR out=$HILFE_OUT"
fi

DIFZ_LANG=de "$DIFZ" --about >/dev/null 2>"$TEST_DIR/env_lang.err"
if grep -q "WARN: i18n missing-locale de" "$TEST_DIR/env_lang.err"; then
	pass "DIFZ_LANG=de warns missing-locale"
else
	fail "DIFZ_LANG=de warns missing-locale" "stderr=$(cat "$TEST_DIR/env_lang.err")"
fi

"$DIFZ" --lang en --about >/dev/null 2>"$TEST_DIR/en_lang.err"
EN_WARN=$(grep -v '^DEBUG BUILD$' "$TEST_DIR/en_lang.err" | grep -v '^$' || true)
if [ -z "$EN_WARN" ]; then
	pass "--lang en does not warn about a missing locale"
else
	fail "--lang en does not warn about a missing locale" "stderr=$EN_WARN"
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
