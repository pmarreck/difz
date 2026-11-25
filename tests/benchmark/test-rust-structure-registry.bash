#!/usr/bin/env bash
set -u
probe=${1:?prepared probe required}
root=$PWD
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-structure-registry.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
cp tests/benchmark/rust-structure-growth.lua "$work/gate.lua" || exit 1
run_gate() { (cd "$work" && luajit gate.lua "$probe" --coverage-only) > "$work/out" 2>&1; }
cp profiling-rust-structure.json "$work/profiling-rust-structure.json" || exit 1
run_gate || { cat "$work/out" >&2; exit 1; }
for mutation in missing duplicate stale wrong-model wrong-axis wrong-scope wrong-sizes wrong-metric; do
	case "$mutation" in
		missing) expression='.cases |= .[1:]';;
		duplicate) expression='.cases += [.cases[0]]';;
		stale) expression='.cases[0].operation = "missing-operation"';;
		wrong-model) expression='.cases[0].model = "constant"';;
		wrong-axis) expression='.cases[0].axis = "entries"';;
		wrong-scope) expression='.cases[0].mode = "bm"';;
		wrong-sizes) expression='.cases[0].sizes[0] += 1';;
		wrong-metric) expression='.cases[0].metric = "wall_ns"';;
		*) exit 1;;
	esac
	jq "$expression" "$root/profiling-rust-structure.json" > "$work/profiling-rust-structure.json" || exit 1
	if run_gate; then printf 'FAIL accepted bad structure registry: %s\n' "$mutation" >&2; exit 1; fi
done
printf 'PASS metadata/directory registry: compiled positive control and eight independently altered declarations\n'
