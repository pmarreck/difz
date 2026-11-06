#!/usr/bin/env bash
set -u
probe=${1:?prepared probe required}
root=$PWD
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-growth-registry.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
cp tests/benchmark/rust-file-growth.lua "$work/gate.lua" || exit 1
run_gate() { (cd "$work" && luajit gate.lua "$probe" --coverage-only) > "$work/out" 2>&1; }
cp profiling-rust-file.json "$work/profiling-rust-file.json" || exit 1
run_gate || { cat "$work/out" >&2; exit 1; }
for mutation in missing duplicate stale wrong-model wrong-scope cross-regime; do
	case "$mutation" in
		missing) expression='.cases |= .[1:]';;
		duplicate) expression='.cases += [.cases[0]]';;
		stale) expression='.cases[0].operation = "missing-operation"';;
		wrong-model) expression='.cases[0].model = "constant"';;
		wrong-scope) expression='.cases[0].mode = "bm"';;
		cross-regime) expression='.cases[0].sizes = [262144,524288,1048576,2097152]';;
		*) exit 1;;
	esac
	jq "$expression" "$root/profiling-rust-file.json" > "$work/profiling-rust-file.json" || exit 1
	if run_gate; then printf 'FAIL accepted bad growth registry: %s\n' "$mutation" >&2; exit 1; fi
done
printf 'PASS growth registry: compiled positive control and six rejected omissions, stale declarations or mixed regimes\n'
