#!/usr/bin/env bash
# Independent byte checks for the prepared timing probe, outside measurements.
set -u
probe="${DIFZ_CODEC_PROBE:-}"
zstd="${ZSTD_CLI:-}"
if [ ! -f "$probe" ] || [ ! -x "$probe" ]; then
	printf 'FAIL a Nix-prepared codec probe is required\n' >&2; exit 1
fi
if [ ! -f "$zstd" ] || [ ! -x "$zstd" ]; then
	printf 'FAIL the pinned zstdz CLI is required\n' >&2; exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-probe.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
source="$work/source with spaces"
target="$work/target"
frame="$work/frame"
output="$work/output"
for shape in empty new-binary edited-binary; do
	: > "$source"
	: > "$target"
	if [ "$shape" != empty ]; then printf 'abc\000\377\200abcdefghijk' > "$target"; fi
	if [ "$shape" = edited-binary ]; then printf 'abc\000\377\200ABCdefghijk' > "$source"; fi
	expected=$(stat -c %s "$target" 2>/dev/null) || expected=$(stat -f %z "$target") || exit 1
	prefix=()
	[ ! -s "$source" ] || prefix=(--patch-from="$source")
	for codec in c rusty structured structured-owned; do
		if ! "$probe" encode "$codec" "$source" "$target" "$frame" > "$work/encode.json" 2> "$work/stderr"; then
			printf 'FAIL %s %s encode\n' "$shape" "$codec" >&2; cat "$work/stderr" >&2; exit 1
		fi
		[ ! -s "$work/stderr" ] || exit 1
		bytes=$(stat -c %s "$frame" 2>/dev/null) || bytes=$(stat -f %z "$frame") || exit 1
		if [ "$codec" = structured ]; then cp "$frame" "$work/structured-reference" || exit 1; fi
		if [ "$codec" = structured-owned ]; then cmp -s "$frame" "$work/structured-reference" || exit 1; fi
		jq -e --argjson bytes "$bytes" '.wall_ns > 0 and .output_bytes == $bytes' "$work/encode.json" > /dev/null || exit 1
		"$zstd" -q -f -d "${prefix[@]}" "$frame" -o "$output" > "$work/stdout" 2> "$work/stderr" || { cat "$work/stderr" >&2; exit 1; }
		cmp -s "$target" "$output" || exit 1
		for decoder in c rusty structured structured-owned; do
			"$probe" decode "$decoder" "$source" "$frame" "$output" "$expected" > "$work/decode.json" 2> "$work/stderr" || { cat "$work/stderr" >&2; exit 1; }
			[ ! -s "$work/stderr" ] || exit 1
			jq -e --argjson bytes "$expected" '.wall_ns > 0 and .output_bytes == $bytes' "$work/decode.json" > /dev/null || exit 1
			cmp -s "$target" "$output" || exit 1
		done
	done
done
for codec in bad '' '--help'; do
	"$probe" encode "$codec" "$source" "$target" "$frame" > "$work/stdout" 2> "$work/stderr"
	status=$?
	if [ "$status" -eq 0 ] || [ -s "$work/stdout" ] || [ ! -s "$work/stderr" ]; then
		printf 'FAIL unknown codec classification\n' >&2; exit 1
	fi
done
printf 'PASS all probe encoders cross-apply through all decoders and pinned zstdz\n'
