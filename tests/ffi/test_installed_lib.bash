#!/usr/bin/env bash
# Prove an external C consumer can link using only installed package files.
set -u

ERRORS=0
TESTS=0
PREFIX="${DIFZ_PREFIX:-./zig-out}"

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

printf "difz installed-library tests\n"
printf "============================\n"

if command -v zig >/dev/null 2>&1; then
	CC=(zig cc)
elif command -v cc >/dev/null 2>&1; then
	CC=(cc)
else
	fail "C compiler available" "neither zig cc nor cc is on PATH"
	printf "%d tests, %d failed\n" "$TESTS" "$ERRORS"
	exit "$ERRORS"
fi
pass "C compiler available (${CC[*]})"

HEADER="$PREFIX/include/difz.h"
ARCHIVE="$PREFIX/lib/libdifz.a"
if [ ! -f "$HEADER" ]; then
	fail "installed header exists" "missing $HEADER"
	printf "%d tests, %d failed\n" "$TESTS" "$ERRORS"
	exit "$ERRORS"
fi
if [ ! -f "$ARCHIVE" ]; then
	fail "installed archive exists" "missing $ARCHIVE"
	printf "%d tests, %d failed\n" "$TESTS" "$ERRORS"
	exit "$ERRORS"
fi
pass "installed header and archive exist"

if grep -q 'extern "C"' "$HEADER"; then
	pass "header has C++ linkage guards"
else
	fail "header has C++ linkage guards" "no extern \"C\" in $HEADER"
fi

if grep -B3 '^void difz_free' "$HEADER" | grep -q 'difz_directory_diff'; then
	pass "difz_free documents directory output ownership"
else
	fail "difz_free documents directory output ownership" "comment omits directory outputs"
fi

WORK="${TMPDIR:-/tmp}/difz_ffi_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

LINK_ERR=$WORK/link.err
if "${CC[@]}" -no-pie -I "$PREFIX/include" tests/ffi/caller.c "$ARCHIVE" -lm -o "$WORK/caller" 2>"$LINK_ERR"; then
	pass "external C caller links against installed libdifz.a"
else
	fail "external C caller links against installed libdifz.a" "$(tr '\n' ' ' < "$LINK_ERR" | cut -c1-400)"
	printf "%d tests, %d failed\n" "$TESTS" "$ERRORS"
	exit "$ERRORS"
fi

if "$WORK/caller"; then
	pass "external C caller round-trips a 6-byte buffer"
else
	fail "external C caller round-trips a 6-byte buffer" "exit $?"
fi

if command -v nm >/dev/null 2>&1; then
	leaks=$(nm -g --defined-only "$ARCHIVE" 2>/dev/null | awk '/ [TWw] / {print $NF}' | sed 's/^_//' | grep -E '^(blar_|z7z_)' || true)
	if [ -z "$leaks" ]; then
		pass "installed archive does not export blar_ or z7z_ globals"
	else
		fail "installed archive does not export blar_ or z7z_ globals" "$(printf '%s\n' "$leaks" | tr '\n' ' ' | cut -c1-300)"
	fi
else
	fail "installed archive does not export blar_ or z7z_ globals" "nm not on PATH"
fi

printf "\n%d tests, %d failed\n" "$TESTS" "$ERRORS"
exit "$ERRORS"
