#!/usr/bin/env bash
# Exercise the Nix-prepared Rust consumer of the installed Zig C ABI.
set -u
caller="${DIFZ_RUST_CALLER:-}"
if [ ! -f "$caller" ] || [ ! -x "$caller" ]; then
	printf 'FAIL a regular executable DIFZ_RUST_CALLER from nix build is required\n' >&2
	exit 1
fi
if run_output=$(UBSAN_OPTIONS=halt_on_error=1 "$caller" 2>&1); then
	if [ -n "$run_output" ]; then
		printf 'FAIL Rust C ABI produced unexpected output: %s\n' "$run_output" >&2
		exit 1
	fi
	printf 'PASS Rust C ABI: binary and empty buffers, ownership, limits, all omission masks, directory apply\n'
else
	printf 'FAIL Rust C ABI runtime: %s\n' "$run_output" >&2
	exit 1
fi
case "$(uname -s)" in
	Linux) dependencies=$(readelf -d "$caller" 2>&1); status=$?;;
	Darwin) dependencies=$(otool -L "$caller" 2>&1); status=$?;;
	*) printf 'FAIL dependency inspection is unavailable on this platform\n' >&2; exit 1;;
esac
if [ "$status" -ne 0 ]; then
	printf 'FAIL inspect Rust executable dependencies: %s\n' "$dependencies" >&2
	exit 1
fi
if printf '%s\n' "$dependencies" | grep -Ei 'lib(difz|zstd|pcre2).*(so|dylib)'; then
	printf 'FAIL Rust executable requires a separate codec library\n' >&2
	exit 1
fi
printf 'PASS Rust executable has no dynamic difz, zstd, or PCRE2 dependency\n'
