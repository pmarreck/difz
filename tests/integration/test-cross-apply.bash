#!/usr/bin/env bash
# Qualify the acceptance gate with real artifacts and deliberately broken adapters.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
gate="$root/tests/acceptance/cross-apply"
[ -x "$gate" ] || { printf 'FAIL cross-apply gate is missing\n' >&2; exit 1; }
reference=${DIFZ:?a prepared reference is required}
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-cross-contract.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
record="$work/calls"
candidate="$work/candidate with spaces"
printf '#!%s\n' "$BASH" > "$candidate" || exit 1
cat >> "$candidate" <<'ADAPTER'
set -u
printf called >> "$DIFZ_CROSS_RECORD"
if [ "$DIFZ_CROSS_MODE" = no-encode ] && [ "$1" != --patch ]; then exit 0; fi
if [ "$DIFZ_CROSS_MODE" = no-apply ] && [ "$1" = --patch ]; then exit 0; fi
"$DIFZ_CROSS_REFERENCE" "$@"
status=$?
if [ "$DIFZ_CROSS_MODE" = mask-failure ]; then exit 0; fi
if [ "$DIFZ_CROSS_MODE" = abort-status ] && [ "$status" -ne 0 ] && [ ! -e "${@: -1}" ]; then exit 134; fi
[ "$status" -eq 0 ] || exit "$status"
output=${@: -1}
if [ "$DIFZ_CROSS_MODE" = corrupt-apply ] && [ "$1" = --patch ] && [ -f "$output" ] && [ -s "$output" ]; then
	printf X | dd of="$output" bs=1 count=1 conv=notrunc 2>/dev/null || exit 1
fi
if [ "$DIFZ_CROSS_MODE" = corrupt-tree ] && [ "$1" = --patch ] && [ -f "$output/bin/app" ]; then
	printf X | dd of="$output/bin/app" bs=1 count=1 conv=notrunc 2>/dev/null || exit 1
fi
if [ "$DIFZ_CROSS_MODE" = wrong-tree-mode ] && [ "$1" = --patch ] && [ -f "$output/bin/app" ]; then
	chmod 700 "$output/bin/app" || exit 1
fi
exit 0
ADAPTER
chmod +x "$candidate" || exit 1
export DIFZ_CROSS_REFERENCE="$reference" DIFZ_CROSS_RECORD="$record"
export DIFZ_CROSS_MODE=pass
"$gate" "$reference" "$candidate" > "$work/out" 2> "$work/err" || {
	cat "$work/err" >&2; exit 1;
}
[ -s "$record" ] && [ ! -s "$work/err" ] || exit 1
grep -Fxq 'PASS cross-apply: files=6 trees=2 encoder/decoder-pairs=4' "$work/out" || {
	printf 'FAIL cross-apply case set is incomplete\n' >&2; exit 1;
}
for mode in no-encode no-apply corrupt-apply corrupt-tree wrong-tree-mode mask-failure abort-status; do
	DIFZ_CROSS_MODE=$mode "$gate" "$reference" "$candidate" > "$work/out" 2> "$work/err"
	status=$?
	if [ "$status" -eq 0 ] || [ ! -s "$work/err" ]; then
		printf 'FAIL cross-apply gate accepted %s\n' "$mode" >&2; exit 1
	fi
done
mkdir "$work/directory" || exit 1
printf plain > "$work/non-executable" || exit 1
paths=("$candidate" "$work/missing" "$work/directory" "$work/non-executable")
for left in 0 1 2 3; do
	for right in 0 1 2 3; do
		[ "$left,$right" != 0,0 ] || continue
		: > "$record"
		"$gate" "${paths[$left]}" "${paths[$right]}" > "$work/out" 2> "$work/err"
		status=$?
		if [ "$status" -eq 0 ] || [ -s "$record" ] || [ ! -s "$work/err" ]; then
			printf 'FAIL cross-apply artifact classification %s %s\n' "$left" "$right" >&2; exit 1
		fi
	done
done
printf 'PASS cross-apply gate: real reference, seven broken adapters, 15 invalid artifact pairs\n'
