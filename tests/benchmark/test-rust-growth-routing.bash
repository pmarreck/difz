#!/usr/bin/env bash
# Both historical domains must execute even if the first is unbaselined/fails.
set -u
root=$PWD
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-growth-routing.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/tools" || exit 1
cp tests/benchmark/run-rust-big-o "$work/router" || exit 1
printf '#!%s\nexit 0\n' "$BASH" > "$work/tools/luajit" || exit 1
printf '#!%s\n' "$BASH" > "$work/tools/performance-profile" || exit 1
cat >> "$work/tools/performance-profile" <<'PROFILE'
[ "$1" = run ] && [ "$2" = --config ] || exit 65
printf '%s\n' "$3" >> "$DIFZ_ROUTE_RECORD" || exit 66
case "$3" in
    profiling-rust-file.json) exit "$DIFZ_FILE_STATUS";;
    profiling-rust-structure.json) exit "$DIFZ_STRUCTURE_STATUS";;
    *) exit 67;;
esac
PROFILE
chmod +x "$work/tools/luajit" "$work/tools/performance-profile" || exit 1
printf 'profiling-rust-file.json\nprofiling-rust-structure.json\n' > "$work/expected" || exit 1
export DIFZ_RUST_FILE_PROBE="$work/prepared probe" DIFZ_ROUTE_RECORD="$work/called"
for pair in '0 0 0' '0 1 1' '0 3 3' '1 0 1' '1 1 1' '1 3 1' '3 0 3' '3 1 1' '3 3 3'; do
	read -r DIFZ_FILE_STATUS DIFZ_STRUCTURE_STATUS expected <<< "$pair"
	export DIFZ_FILE_STATUS DIFZ_STRUCTURE_STATUS
	: > "$DIFZ_ROUTE_RECORD"
	(cd "$work" && PATH="$work/tools:$PATH" bash router) > "$work/out" 2> "$work/err"
	actual=$?
	if [ "$actual" -ne "$expected" ] || ! cmp "$work/expected" "$DIFZ_ROUTE_RECORD"; then
		cat "$work/out" "$work/err" >&2
		printf 'FAIL growth routing statuses %s\n' "$pair" >&2; exit 1
	fi
done
printf 'PASS both growth domains execute for all nine pass/fail/unbaselined status pairs\n'
