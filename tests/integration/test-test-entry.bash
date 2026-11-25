#!/usr/bin/env bash
# Exercise the real complete entry point with disposable Nix/admission adapters.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-test-entry.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
project="$work/project with spaces"
tools="$work/tools"
mkdir -p "$project/tests/nix" "$project/.mechatron-prime" "$tools" "$work/home" || exit 1
cp "$root/test" "$project/test" || exit 1
cp "$root/big_o" "$project/big_o" || exit 1
cp "$root/.mechatron-prime/targets" "$project/.mechatron-prime/targets" || exit 1
printf 'exit 0\n' > "$project/tests/nix/test_flake_outputs.bash"
for tool in bash dirname mktemp mkdir rm jq grep ln readlink cat touch; do
	path=$(command -v "$tool") || exit 1
	ln -s "$path" "$tools/$tool" || exit 1
done
export DIFZ_BENCH_HISTORY="$work/history"
unset PERFORMANCE_HISTORY_URL
printf '#!%s\nprintf "Linux\\n"\n' "$BASH" > "$tools/uname"
printf '#!%s\n' "$BASH" > "$tools/nix"
cat >> "$tools/nix" <<'NIX'
set -u
operation=$1; shift
case "$operation" in
	eval) printf 'x86_64-linux';;
	develop)
		while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
		[ "$#" -gt 0 ] || exit 30
		shift; exec "$@";;
	build)
		printf '%s\n' "$@" > "$NIX_ENTRY_ARGS"
		link=
		while [ "$#" -gt 0 ]; do
			if [ "$1" = --out-link ]; then shift; link=${1:-}; fi
			shift
		done
		[ -n "$link" ] || { printf 'FAIL Nix outputs have no retained link\n' >&2; exit 31; }
		if grep -Fxq -- --no-link "$NIX_ENTRY_ARGS"; then exit 32; fi
		if [ "$NIX_ENTRY_KIND" = test ]; then
		while IFS= read -r target; do
			if [ "${target#checks.}" != "$target" ]; then
				grep -Fxq -- ".#$target" "$NIX_ENTRY_ARGS" || exit 33
			fi
		done < .mechatron-prime/targets
		else
			grep -Fxq -- '.#rust-core-tests' "$NIX_ENTRY_ARGS" || exit 33
		fi
		ln -s "$NIX_ENTRY_PREFIX" "$link" || exit 34
		printf '%s\n' "$link" > "$NIX_ENTRY_LINK"
		if [ "$NIX_ENTRY_KIND" = test ]; then
			jq -n --arg prefix "$NIX_ENTRY_PREFIX" '[{outputs:{out:$prefix}}]'
		else printf '%s\n' "$NIX_ENTRY_PREFIX"; fi;;
	*) exit 35;;
esac
NIX
printf '#!%s\n' "$BASH" > "$tools/build-budget"
cat >> "$tools/build-budget" <<'BUDGET'
set -u
[ "$#" -ge 4 ] && [ "$1" = --project ] && [ "$2" = difz ] && [ "$3" = -- ] || exit 40
shift 3
touch "$NIX_ENTRY_ADMITTED" || exit 41
exec "$@"
BUDGET
mkdir -p "$project/tests" || exit 1
cat > "$project/tests/run-host-tests" <<'HOST'
set -u
link=$(cat "$NIX_ENTRY_LINK") || exit 50
[ -L "$link" ] && [ "$(readlink "$link")" = "$1" ] && [ -e "$NIX_ENTRY_ADMITTED" ] || exit 51
touch "$NIX_ENTRY_RAN" || exit 52
exit "$NIX_ENTRY_STATUS"
HOST
chmod +x "$tools/nix" "$tools/build-budget" "$tools/uname" || exit 1
mkdir -p "$project/tests/benchmark" || exit 1
cat > "$project/tests/benchmark/run-rust-big-o" <<'GROWTH'
[ "${DIFZ_RUST_FILE_PROBE:-}" = "$NIX_ENTRY_PREFIX/bin/difz-core-consumer" ] || exit 53
bash tests/run-host-tests "$NIX_ENTRY_PREFIX"
GROWTH
for entry in test big_o; do
for status in 0 7; do
	case_dir="$work/$entry-case-$status"
	mkdir -p "$case_dir/package-difz-host-tests/bin" "$case_dir/tmp" || exit 1
	printf '#!%s\nexit 65\n' "$BASH" > "$case_dir/package-difz-host-tests/bin/difz-core-consumer"
	chmod +x "$case_dir/package-difz-host-tests/bin/difz-core-consumer" || exit 1
	printf retained > "$case_dir/package-difz-host-tests/sentinel"
	export NIX_ENTRY_PREFIX="$case_dir/package-difz-host-tests" NIX_ENTRY_ARGS="$case_dir/args" NIX_ENTRY_LINK="$case_dir/link" NIX_ENTRY_RAN="$case_dir/ran" NIX_ENTRY_ADMITTED="$case_dir/admitted" NIX_ENTRY_STATUS="$status"
	export NIX_ENTRY_KIND="$entry"
	PATH="$tools" HOME="$work/home" TMPDIR="$case_dir/tmp" "$BASH" "$project/$entry" > "$case_dir/out" 2> "$case_dir/err"
	actual=$?
	expected=0; [ "$status" -eq 0 ] || expected=1
	[ "$entry" != big_o ] || expected=$status
	if [ "$actual" -ne "$expected" ] || [ ! -e "$NIX_ENTRY_RAN" ]; then
		cat "$case_dir/out" "$case_dir/err" >&2; printf 'FAIL complete test entry lifecycle case %d\n' "$status" >&2; exit 1
	fi
	link=$(cat "$NIX_ENTRY_LINK") || exit 1
	if [ -e "$link" ] || [ -L "$link" ] || [ -d "$(dirname "$link")" ] || [ "$(cat "$NIX_ENTRY_PREFIX/sentinel")" != retained ]; then
		printf 'FAIL test roots cleanup removed package data or retained roots\n' >&2; exit 1
	fi
done
done
rm -- "$tools/build-budget" || exit 1
for entry in test big_o; do
case_dir="$work/$entry-no-budget"
mkdir -p "$case_dir/package-difz-host-tests/bin" "$case_dir/tmp" || exit 1
printf '#!%s\nexit 65\n' "$BASH" > "$case_dir/package-difz-host-tests/bin/difz-core-consumer"
chmod +x "$case_dir/package-difz-host-tests/bin/difz-core-consumer" || exit 1
export NIX_ENTRY_PREFIX="$case_dir/package-difz-host-tests" NIX_ENTRY_ARGS="$case_dir/args" NIX_ENTRY_LINK="$case_dir/link" NIX_ENTRY_RAN="$case_dir/ran" NIX_ENTRY_ADMITTED="$case_dir/admitted" NIX_ENTRY_STATUS=0
export NIX_ENTRY_KIND="$entry"
PATH="$tools" HOME="$work/home" TMPDIR="$case_dir/tmp" "$BASH" "$project/$entry" > "$case_dir/out" 2> "$case_dir/err"
actual=$?
if [ "$actual" -eq 0 ] || [ -e "$NIX_ENTRY_RAN" ] || ! grep -Fq 'build-budget must be available on PATH' "$case_dir/err"; then
	cat "$case_dir/out" "$case_dir/err" >&2; printf 'FAIL missing admission helper did not refuse execution\n' >&2; exit 1
fi
done
printf 'PASS test/growth entry points: every required check, retained roots through admitted execution, success/failure cleanup and missing-admission refusal\n'
