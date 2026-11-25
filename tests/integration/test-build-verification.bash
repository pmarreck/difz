#!/usr/bin/env bash
# Called by the Nix check with exact native products; mutable copies stay there.
set -u
zig_product=${1:?prepared Zig product required}
rust_release=${2:?prepared Rust release product required}
rust_debug=${3:?prepared Rust debug product required}
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
source "$root/scripts/build-selection.bash"
source "$root/scripts/verify-build-output.bash"
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-build-verify.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
platforms=(linux-amd64 linux-arm64 macos-arm64 mswin-amd64 mswin-arm64)
descriptions=('ELF 64-bit LSB pie executable, x86-64' 'ELF 64-bit LSB executable, ARM aarch64' 'Mach-O 64-bit arm64 executable' 'PE32+ executable (console) x86-64, for MS Windows' 'PE32+ executable (console) Aarch64, for MS Windows')
for ((i=0; i<5; i++)); do for ((j=0; j<5; j++)); do
	difz_verify_header "${platforms[i]}" "${descriptions[j]}"; status=$?
	if [ "$i" -eq "$j" ]; then [ "$status" -eq 0 ] || exit 1
	else [ "$status" -ne 0 ] || { printf 'FAIL wrong executable header accepted\n' >&2; exit 1; }; fi
done; done
for text in 'ASCII text' 'ELF 32-bit LSB executable, Intel 80386' 'ELF 64-bit LSB relocatable, x86-64' 'PE32+ executable (DLL) x86-64'; do
	for pf in "${platforms[@]}"; do if difz_verify_header "$pf" "$text"; then exit 1; fi; done
done
DIFZ_BUILD_PFS=("${platforms[@]}")
host=$(difz_build_normalize_host "$(uname -s)" "$(uname -m)") || exit 1
zig_variant=-; rust_variant=-
case "$host" in linux-*) zig_variant=musl; rust_variant=gnu;; esac
difz_verify_product "$zig_product" zig "$host" "$zig_variant" ReleaseFast "$host" || exit 1
difz_verify_product "$rust_release" rust "$host" "$rust_variant" release "$host" || exit 1
difz_verify_product "$rust_debug" rust "$host" "$rust_variant" debug "$host" || exit 1
mkdir -p "$work/corrupt/bin" "$work/corrupt/lib" "$work/corrupt/include" || exit 1
ln -s "$zig_product/lib/libdifz.a" "$work/corrupt/lib/libdifz.a" || exit 1
ln -s "$zig_product/include/difz.h" "$work/corrupt/include/difz.h" || exit 1
cp "$zig_product/bin/difz" "$work/corrupt/bin/difz" || exit 1
chmod u+w "$work/corrupt/bin/difz" || exit 1
printf corrupt | dd of="$work/corrupt/bin/difz" bs=1 conv=notrunc status=none || exit 1
if difz_verify_product "$work/corrupt" zig "$host" "$zig_variant" ReleaseFast "$host" > "$work/out" 2> "$work/err"; then
	printf 'FAIL corrupted prepared executable accepted\n' >&2; exit 1
fi
if difz_verify_product "$rust_release" rust "$host" "$rust_variant" debug "$host" > "$work/out" 2> "$work/err"; then
	printf 'FAIL release archive accepted as a debug product\n' >&2; exit 1
fi
# This controlled file-reader adapter isolates the execution-boundary check.
# Real native headers and corruption were checked above using the actual reader.
mkdir -p "$work/foreign/bin" "$work/foreign/lib" "$work/foreign/include" "$work/tools" || exit 1
printf '#!%s\ntouch "$DIFZ_FOREIGN_EXECUTED"\nexit 65\n' "$BASH" > "$work/foreign/bin/difz.exe"
printf archive > "$work/foreign/lib/libdifz.a"
printf header > "$work/foreign/include/difz.h"
printf '#!%s\nprintf "PE32+ executable (console) Aarch64, for MS Windows\\n"\n' "$BASH" > "$work/tools/file"
chmod +x "$work/foreign/bin/difz.exe" "$work/tools/file" || exit 1
export DIFZ_FOREIGN_EXECUTED="$work/foreign-executed"
PATH="$work/tools:$PATH" difz_verify_product "$work/foreign" zig mswin-arm64 - ReleaseFast "$host" || exit 1
[ ! -e "$DIFZ_FOREIGN_EXECUTED" ] || { printf 'FAIL foreign executable was invoked\n' >&2; exit 1; }
printf 'PASS product verification: all header/platform pairs, real native backends/profiles, corrupted executable, profile mismatch and foreign execution refusal\n'
