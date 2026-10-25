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
		jq -e --argjson bytes "$bytes" '.wall_ns > 0 and .cpu_ns > 0 and .output_bytes == $bytes' "$work/encode.json" > /dev/null || exit 1
		"$zstd" -q -f -d "${prefix[@]}" "$frame" -o "$output" > "$work/stdout" 2> "$work/stderr" || { cat "$work/stderr" >&2; exit 1; }
		cmp -s "$target" "$output" || exit 1
		for decoder in c rusty structured structured-owned; do
			"$probe" decode "$decoder" "$source" "$frame" "$output" "$expected" > "$work/decode.json" 2> "$work/stderr" || { cat "$work/stderr" >&2; exit 1; }
			[ ! -s "$work/stderr" ] || exit 1
			jq -e --argjson bytes "$expected" '.wall_ns > 0 and .cpu_ns > 0 and .output_bytes == $bytes' "$work/decode.json" > /dev/null || exit 1
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

for shape in empty ordinary prefix; do
	: > "$source"; : > "$target"
	if [ "$shape" != empty ]; then
		printf '0123456789abcdef0123456789abcdef\000\3770123456789abcdef0123456789abcdef' > "$target"
	fi
	if [ "$shape" = prefix ]; then cp "$target" "$source" || exit 1; fi
	expected=$(wc -c < "$target")
	frames=$(( (expected + 7) / 8 )); [ "$frames" -ne 0 ] || frames=1
	for workers in 1 4 8; do
		"$probe" encode c-chunks "$source" "$target" "$frame" 8 "$workers" > "$work/chunk-encode.json" 2> "$work/stderr" || { cat "$work/stderr" >&2; exit 1; }
		[ ! -s "$work/stderr" ] || exit 1
		used=$workers; [ "$used" -le "$frames" ] || used=$frames
		jq -e --argjson frames "$frames" --argjson used "$used" '.frames == $frames and .workers_used == $used and .wall_ns > 0' "$work/chunk-encode.json" > /dev/null || exit 1
		if [ "$workers" = 1 ]; then cp "$frame" "$work/chunk-reference" || exit 1; else cmp -s "$frame" "$work/chunk-reference" || exit 1; fi
		# A persistent raw dictionary lets the separate native CLI read every frame.
		prefix=(); [ ! -s "$source" ] || prefix=(-D "$source")
		"$zstd" -q -f -d --long=31 "${prefix[@]}" "$frame" -o "$output" > "$work/stdout" 2> "$work/stderr" || { cat "$work/stderr" >&2; exit 1; }
		cmp -s "$target" "$output" || exit 1
		for decoder_workers in 1 4 8; do
			"$probe" decode c-chunks "$source" "$frame" "$output" "$expected" "$decoder_workers" > "$work/chunk-decode.json" 2> "$work/stderr" || { cat "$work/stderr" >&2; exit 1; }
			[ ! -s "$work/stderr" ] || exit 1
			cmp -s "$target" "$output" || exit 1
			used=$decoder_workers; [ "$used" -le "$frames" ] || used=$frames
			jq -e --argjson frames "$frames" --argjson used "$used" '.frames == $frames and .workers_used == $used' "$work/chunk-decode.json" > /dev/null || exit 1
		done
	done
done
# Tiny chunks may legitimately use only literals. This larger unique-counter
# fixture forces useful full-source references before testing their absence.
for ((index=0; index<8192; index++)); do printf '%08x' "$index"; done > "$source"
cp "$source" "$target" || exit 1
expected=$(wc -c < "$target")
"$probe" encode c-chunks "$source" "$target" "$frame" 4096 4 > "$work/chunk-encode.json" 2> "$work/stderr" || exit 1
[ "$(wc -c < "$frame")" -lt "$((expected / 8))" ] || exit 1
"$zstd" -q -f -d --long=31 -D "$source" "$frame" -o "$output" > "$work/stdout" 2> "$work/stderr" || exit 1
cmp -s "$target" "$output" || exit 1
mkdir -p "$work/parts" || exit 1
luajit "${DIFZ_SPLIT_ZSTD:?frame reader is required}" "$frame" "$work/parts" > "$work/parts/list" || exit 1
[ "$(wc -l < "$work/parts/list")" -eq 16 ] || exit 1
: > "$work/independent-output"
while IFS= read -r part; do
	"$zstd" -q -f -d --patch-from="$source" "$work/parts/$part" -o "$work/part-output" > "$work/stdout" 2> "$work/stderr" || exit 1
	cat "$work/part-output" >> "$work/independent-output" || exit 1
done < "$work/parts/list"
cmp -s "$target" "$work/independent-output" || exit 1
: > "$work/no-source"
"$probe" decode c-chunks "$work/no-source" "$frame" "$work/invalid-output" "$expected" 4 > "$work/stdout" 2> "$work/stderr"
status=$?
[ "$status" -ne 0 ] && [ ! -e "$work/invalid-output" ] || { printf 'FAIL prefix negative control\n' >&2; exit 1; }
head -c "$(( $(wc -c < "$frame") - 1 ))" "$frame" > "$work/truncated" || exit 1
"$probe" decode c-chunks "$source" "$work/truncated" "$work/invalid-output" "$expected" 8 > "$work/stdout" 2> "$work/stderr"
status=$?
[ "$status" -ne 0 ] && [ ! -e "$work/invalid-output" ] || { printf 'FAIL truncated multi-frame control\n' >&2; exit 1; }
printf 'PASS independently framed ordinary and prefix streams encode/decode with 1/4/8 workers\n'
