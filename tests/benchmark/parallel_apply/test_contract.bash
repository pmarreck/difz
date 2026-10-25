#!/usr/bin/env bash
# A previous successful sample must never let skipped decoding pass verification.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/parallel-contract.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export PAR_CHUNK=1 PAR_SIZE=4 PAR_WORKERS=4 PAR_LAYOUT=chunks
export PAR_WORK="$work" PAR_OUTPUT="$work/output" PAR_TARGET="$work/target"
printf 'A\000B\377' > "$PAR_TARGET" || exit 1
valid='{"wall_ns":1,"cpu_ns":1,"frames":4,"workers_used":4,"output_bytes":4}'
for shape in valid absent same-size-corruption wrong-workers wrong-frames wrong-size zero-wall zero-cpu stale; do
	cp "$PAR_TARGET" "$PAR_OUTPUT" || exit 1
	printf '%s\n' "$valid" > "$work/kernel.json"
	: > "$work/kernels.ndjson"
	case "$shape" in
		valid) :;;
		absent) rm -- "$PAR_OUTPUT";;
		same-size-corruption) printf 'A\000C\377' > "$PAR_OUTPUT";;
		wrong-workers) jq '.workers_used=1' <<< "$valid" > "$work/kernel.json";;
		wrong-frames) jq '.frames=1' <<< "$valid" > "$work/kernel.json";;
		wrong-size) jq '.output_bytes=3' <<< "$valid" > "$work/kernel.json";;
		zero-wall) jq '.wall_ns=0' <<< "$valid" > "$work/kernel.json";;
		zero-cpu) jq '.cpu_ns=0' <<< "$valid" > "$work/kernel.json";;
		stale)
			bash "$root/tests/benchmark/parallel_apply/verify" prepare || exit 1
			[ ! -e "$PAR_OUTPUT" ] && [ ! -e "$work/kernel.json" ] || exit 1
			# A no-op decoder can print plausible metrics while producing no bytes.
			printf '%s\n' "$valid" > "$work/kernel.json";;
	esac
	bash "$root/tests/benchmark/parallel_apply/verify" > "$work/stdout" 2> "$work/stderr"
	status=$?
	if [ "$shape" = valid ]; then
		[ "$status" -eq 0 ] && [ "$(wc -l < "$work/kernels.ndjson")" -eq 1 ] || exit 1
	else
		if [ "$status" -eq 0 ] || [ -s "$work/kernels.ndjson" ]; then
			printf 'FAIL parallel sample verification accepted %s\n' "$shape" >&2; exit 1
		fi
	fi
done
printf 'PASS parallel verification classifies valid work, corruption, false metrics, and stale output\n'
