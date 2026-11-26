#!/usr/bin/env bash
# Nested ARM64 interpreter capabilities must preserve the read-only host boundary.
set -uo pipefail
fail() { printf 'FAIL ARM64 isolation: %s\n' "$*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'expected source, QEMU and ARM64 probe'
source=$1 qemu=$2 probe=$3
boundary="$source/scripts/run-tests-isolated"
helper="$source/scripts/run-arm64-test.bash"
canaries="$source/tests/integration/test_isolation.bash"
work=$(mktemp -d "${TMPDIR:?}/difz-arm64-isolation.XXXXXXXX") || fail 'fixture allocation'
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/protected" "$work/home" "$work/scratch" || fail 'fixture directories'
setup() {
	for action in relative absolute symlink published-link replace-link rename chmod create; do
		local base="$work/protected/$action"
		mkdir -p "$base/bin" || return 1
		printf 'original\n' > "$base/sentinel" || return 1
		chmod 644 "$base/sentinel" || return 1
		ln -sfn ../sentinel "$base/bin/tool" || return 1
		rm -f -- "$base/new" "$base/renamed" || return 1
	done
}
setup || fail 'initial fixture'
cd "$work/protected" || fail 'fixture cwd'
HOME="$work/home" TEST_WORKSPACE="$work/scratch" bash "$canaries" --child allowed || fail 'unconfined write controls'
setup || fail 'reset fixture'
bash "$boundary" -- bash "$helper" "$qemu" "$probe" bash "$canaries" --child denied || fail 'nested forbidden-write controls'
for action in relative absolute symlink published-link replace-link rename chmod create; do
	base="$work/protected/$action"
	[[ $(cat "$base/sentinel") == original && $(stat -c %a "$base/sentinel") == 644 ]] || fail "changed sentinel: $action"
	[[ $(readlink "$base/bin/tool") == ../sentinel && ! -e $base/new && ! -e $base/renamed ]] || fail "changed paths: $action"
done
status=0
bash "$boundary" -- bash "$helper" "$qemu" "$probe" bash -c 'exit 23' || status=$?
[[ $status == 23 ]] || fail "child exit not propagated: $status"
bash "$boundary" -- bash "$helper" "$qemu" "$probe" "$probe" --version > "$work/version" || fail 'registered ELF execution'
grep -E '^wine-[0-9]' "$work/version" > /dev/null || fail 'missing actual ARM64 Wine version'
[[ ! -e /proc/sys/fs/binfmt_misc/difz-test-aarch64 ]] || fail 'registration escaped into parent'
printf 'PASS ARM64 isolation: eight denied write paths, private writes, actual ELF execution, exit status and parent registry\n'
