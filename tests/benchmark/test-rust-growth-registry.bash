#!/usr/bin/env bash
set -u
probe=${1:?prepared probe required}
root=$PWD
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-growth-registry.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
cp tests/benchmark/rust-file-growth.lua "$work/gate.lua" || exit 1
run_gate() { (cd "$work" && luajit gate.lua "${1:-$probe}" --coverage-only) > "$work/out" 2>&1; }
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
cp "$root/profiling-rust-file.json" "$work/profiling-rust-file.json" || exit 1
export REAL_PROBE="$probe"
bash_bin=$(command -v bash) || exit 1
# The controlled wrapper changes only the SDK report, then delegates everything else.
printf '#!%s\nif [ "${1:-}" = --native-parameters ]; then\n "$REAL_PROBE" "$@" | jq "$PROFILE_MUTATION"\nelse\n exec "$REAL_PROBE" "$@"\nfi\n' "$bash_bin" > "$work/wrapper" || exit 1
chmod +x "$work/wrapper" || exit 1
for mutation in window ldm-hash context rate missing unknown workers; do
	case "$mutation" in
		window) PROFILE_MUTATION='.[2].window += 1';;
		ldm-hash) PROFILE_MUTATION='.[2].ldm_hash += 1';;
		context) PROFILE_MUTATION='.[2].context_bytes = 0';;
		rate) PROFILE_MUTATION='.[2].ldm_hash -= 1 | .[2].ldm_rate += 1';;
		missing) PROFILE_MUTATION='del(.[2].block_bytes)';;
		unknown) PROFILE_MUTATION='.[2].unknown_parameter = 1';;
		workers) PROFILE_MUTATION='.[2].workers = 1';;
		*) exit 1;;
	esac
	export PROFILE_MUTATION
	if run_gate "$work/wrapper"; then printf 'FAIL accepted bad native profile: %s\n' "$mutation" >&2; exit 1; fi
done
printf 'PASS growth registry: compiled positive control, six registry mutations, seven native-profile mutations\n'
