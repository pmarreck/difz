#!/usr/bin/env bash
# Pure Nix preparation checks against the actual immutable flake snapshot.
# These records are synthetic test inputs, never release attestations.
set -u
source=${1:-}
case "$source" in /nix/store/*) [ -d "$source" ] || exit 1;; *) exit 1;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-provenance-input.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
source_hash=$(nix hash path "$source") || exit 1
before_lock=$(sha256sum "$source/flake.lock") || exit 1
mkdir "$work/valid" "$work/clean" "$work/uncaptured" "$work/wrong-source" "$work/wrong-revision" "$work/missing" || exit 1
jq -cn --arg hash "$source_hash" '{schema:"build-provenance/v1",available:true,
 source_commit:"0123456789abcdef0123456789abcdef01234567",primary_ref:"refs/heads/yolo",
 primary_tip:"0123456789abcdef0123456789abcdef01234567",primary_base:"0123456789abcdef0123456789abcdef01234567",
 primary_count:42,source_nar_hash:$hash,dirty:true,revision:"r42-012345"}' > "$work/valid/record.json" || exit 1
jq '.source_nar_hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' "$work/valid/record.json" > "$work/wrong-source/record.json" || exit 1
jq '.revision = "r43-012345"' "$work/valid/record.json" > "$work/wrong-revision/record.json" || exit 1
jq '.dirty = false' "$work/valid/record.json" > "$work/clean/record.json" || exit 1
printf '%s\n' '{"schema":"build-provenance/v1","available":false,"reason":"not-captured"}' > "$work/uncaptured/record.json" || exit 1
evaluate() {
	nix eval --offline --no-write-lock-file --override-input build-provenance "path:$work/$1" \
		--json "path:$source#$2" > "$work/out" 2> "$work/err"
}
if ! evaluate valid buildProvenance; then
	printf 'FAIL actual flake rejects valid provenance\n' >&2; cat "$work/err" >&2; exit 1
fi
if ! jq -e --slurpfile expected "$work/valid/record.json" '. == $expected[0]' "$work/out" > /dev/null; then
	printf 'FAIL actual flake did not preserve valid provenance\n' >&2; exit 1
fi
targets=(packages.x86_64-linux.default.drvPath checks.x86_64-linux.build-wrapper.drvPath)
for target in "${targets[@]}"; do
	if ! evaluate valid "$target"; then
		printf 'FAIL actual flake rejects a valid source-bound fixture: %s\n' "$target" >&2; cat "$work/err" >&2; exit 1
	fi
	for invalid in wrong-source wrong-revision missing; do
		if evaluate "$invalid" "$target"; then
			printf 'FAIL actual target ignores invalid provenance: %s %s\n' "$target" "$invalid" >&2; exit 1
		fi
		if [ "$invalid" = missing ]; then
			if ! grep -Fq 'record.json' "$work/err"; then cat "$work/err" >&2; exit 1; fi
		elif ! grep -Fq 'difz build provenance: invalid or source-mismatched record' "$work/err"; then
			cat "$work/err" >&2; exit 1
		fi
	done
done
if ! evaluate clean releaseProvenance; then
	printf 'FAIL actual release gate rejects valid clean provenance\n' >&2; cat "$work/err" >&2; exit 1
fi
if ! jq -e --slurpfile expected "$work/clean/record.json" '. == $expected[0]' "$work/out" > /dev/null; then
	printf 'FAIL actual release gate changed the source record\n' >&2; exit 1
fi
for invalid in valid uncaptured; do
	if evaluate "$invalid" releaseProvenance; then
		printf 'FAIL actual release gate accepts dirty/unavailable provenance\n' >&2; exit 1
	fi
	grep -Fq 'release requires available clean provenance' "$work/err" || { cat "$work/err" >&2; exit 1; }
done
[ "$(sha256sum "$source/flake.lock")" = "$before_lock" ] || { printf 'FAIL provenance override changed the source lockfile\n' >&2; exit 1; }
[ "$(nix hash path "$source")" = "$source_hash" ] || { printf 'FAIL provenance override changed the root NAR\n' >&2; exit 1; }
printf 'PASS actual flake provenance override: valid metadata, two production/check targets, six rejected invalid inputs and unchanged source/lockfile\n'
