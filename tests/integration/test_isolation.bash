#!/usr/bin/env bash
# Qualify the real Linux boundary using disposable protected files.
set -u

if [ "${1:-}" = --child ]; then
	expectation=$2
	for action in relative absolute symlink published-link replace-link rename chmod create; do
		base="$PWD/$action"
		case "$action" in
			relative) (printf changed >> relative/sentinel);;
			absolute) (printf changed >> "$base/sentinel");;
			symlink) ln -s "$base" "$TEST_WORKSPACE/escape" && (printf changed >> "$TEST_WORKSPACE/escape/sentinel");;
			published-link) (printf changed >> "$base/bin/tool");;
			replace-link) ln -sfn other "$base/bin/tool";;
			rename) mv "$base/sentinel" "$base/renamed";;
			chmod) chmod 600 "$base/sentinel";;
			create) (printf changed > "$base/new");;
		esac > "$TEST_WORKSPACE/$action.stdout" 2> "$TEST_WORKSPACE/$action.stderr"
		status=$?
		if [ "$expectation" = allowed ]; then
			[ "$status" -eq 0 ] || { printf 'FAIL unconfined control %s\n' "$action"; exit 1; }
		else
			[ "$status" -ne 0 ] || { printf 'FAIL boundary allowed %s\n' "$action"; exit 1; }
			[ "$(cat "$base/sentinel")" = original ] || exit 1
			[ "$(readlink "$base/bin/tool")" = ../sentinel ] || exit 1
			[ "$(stat -c %a "$base/sentinel")" = 644 ] || exit 1
			[ ! -e "$base/new" ] || exit 1
		fi
	done
	printf private > "$HOME/private" || exit 1
	printf private > "$TEST_WORKSPACE/private" || exit 1
	exit 0
fi
if [ "${1:-}" = --state ]; then
	[ ! -e "$HOME/state" ] || exit 1
	printf '%s' "$2" > "$HOME/state" || exit 1
	cat "$HOME/state"
	exit 0
fi

root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
boundary="$root/scripts/run-tests-isolated"
self="$root/tests/integration/test_isolation.bash"
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-isolation.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/protected" "$work/home" "$work/scratch" || exit 1
setup() {
	for action in relative absolute symlink published-link replace-link rename chmod create; do
		base="$work/protected/$action"
		mkdir -p "$base/bin" || return 1
		printf 'original\n' > "$base/sentinel" || return 1
		chmod 644 "$base/sentinel" || return 1
		ln -sfn ../sentinel "$base/bin/tool" || return 1
		rm -f -- "$base/new" "$base/renamed" || return 1
	done
}
setup || exit 1
cd "$work/protected" || exit 1
HOME="$work/home" TEST_WORKSPACE="$work/scratch" bash "$self" --child allowed || exit 1
setup || exit 1
if ! "$boundary" -- bash "$self" --child denied; then
	printf 'FAIL forbidden-write canaries\n' >&2
	exit 1
fi
for action in relative absolute symlink published-link replace-link rename chmod create; do
	base="$work/protected/$action"
	[ "$(cat "$base/sentinel")" = original ] || exit 1
	[ "$(readlink "$base/bin/tool")" = ../sentinel ] || exit 1
	[ "$(stat -c %a "$base/sentinel")" = 644 ] || exit 1
	[ ! -e "$base/new" ] || exit 1
done
for token in first second; do
	"$boundary" -- bash "$self" --state "$token" > "$work/$token.out" 2> "$work/$token.err" &
	if [ "$token" = first ]; then first_pid=$!; else second_pid=$!; fi
done
wait "$first_pid"; first_status=$?
wait "$second_pid"; second_status=$?
if [ "$first_status" -ne 0 ] || [ "$second_status" -ne 0 ] ||
	[ "$(cat "$work/first.out")" != first ] || [ "$(cat "$work/second.out")" != second ] ||
	[ -s "$work/first.err" ] || [ -s "$work/second.err" ]; then
	printf 'FAIL isolated concurrent HOME state\n' >&2; exit 1
fi
"$boundary" -- bash "$self" --state later > "$work/later.out" || exit 1
[ "$(cat "$work/later.out")" = later ] || exit 1
"$boundary" -- bash -c 'exit 23'
status=$?
[ "$status" -eq 23 ] || { printf 'FAIL boundary exit status\n' >&2; exit 1; }
printf 'PASS isolation: eight forbidden-write paths, writable private state, independent invocations, exit status\n'
