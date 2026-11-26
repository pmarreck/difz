#!/usr/bin/env bash
# Inspect actual executable bytes; producer metadata is not an oracle.
set -eu
binary=${1:?exact executable required}
if [ ! -f "$binary" ] || [ ! -s "$binary" ] || [ ! -x "$binary" ]; then
	printf 'FAIL missing executable: %s\n' "$binary" >&2; exit 1
fi
header=$(readelf -hW "$binary") || exit 1
if ! grep -Eq 'Type:[[:space:]]+(EXEC|DYN)[[:space:]]' <<< "$header"; then
	printf 'FAIL not an ELF executable: %s\n' "$binary" >&2; exit 1
fi
program=$(readelf -lW "$binary") || exit 1
dynamic=$(readelf -dW "$binary") || exit 1
if grep -Eq 'INTERP|Requesting program interpreter' <<< "$program" ||
	grep -Eq '\((NEEDED|RPATH|RUNPATH)\)' <<< "$dynamic"; then
	printf 'FAIL static executable has a loader dependency: %s\n' "$binary" >&2; exit 1
fi
if LC_ALL=C grep -aqF '/nix/store/' "$binary"; then
	printf 'FAIL executable embeds a Nix store path: %s\n' "$binary" >&2; exit 1
fi
printf 'PASS static ELF headers and path-free bytes: %s\n' "$binary"
