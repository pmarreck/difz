#!/usr/bin/env bash
# Link a Rust consumer to the installed Zig archive using a matching target ABI.
set -u

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR" || exit 1
rust_host=$(rustc -vV | awk '/^host:/ {print $2}')
link_flags=()
case "$rust_host" in
	x86_64-unknown-linux-gnu) zig_target=x86_64-linux-gnu; link_flags=(-C link-arg=-no-pie -C link-arg=-lubsan);;
	aarch64-unknown-linux-gnu) zig_target=aarch64-linux-gnu; link_flags=(-C link-arg=-no-pie -C link-arg=-lubsan);;
	x86_64-unknown-linux-musl) zig_target=x86_64-linux-musl; link_flags=(-C link-arg=-no-pie);;
	aarch64-unknown-linux-musl) zig_target=aarch64-linux-musl; link_flags=(-C link-arg=-no-pie);;
	aarch64-apple-darwin) zig_target=aarch64-macos;;
	*) printf 'FAIL Rust FFI host mapping unavailable: %s\n' "$rust_host" >&2; exit 1;;
esac

product="$ROOT_DIR/.cache/rust-ffi/$rust_host/Debug/$$"
prefix="$product/zig"
if build_output=$(zig build lib "-Dtarget=$zig_target" -Doptimize=Debug -j4 --prefix "$prefix" 2>&1); then
	printf 'PASS Zig archive built for Rust host %s\n' "$rust_host"
else
	printf 'FAIL matching Zig archive: %s\n' "$build_output" >&2
	exit 1
fi
if [ ! -f "$prefix/lib/libdifz.a" ] || [ ! -f "$prefix/include/difz.h" ]; then
	printf 'FAIL library-only build did not install the archive and public header\n' >&2
	exit 1
fi
if [ -e "$prefix/bin/difz" ]; then
	printf 'FAIL library-only build also installed the C CLI\n' >&2
	exit 1
fi
if compile_output=$(rustc --edition=2024 tests/ffi/rust_caller.rs -L "native=$prefix/lib" "${link_flags[@]}" -o "$product/rust-caller" 2>&1); then
	printf 'PASS Rust links the installed libdifz archive\n'
else
	printf 'FAIL Rust static link: %s\n' "$compile_output" >&2
	exit 1
fi
if run_output=$(UBSAN_OPTIONS=halt_on_error=1 "$product/rust-caller" 2>&1); then
	if [ -n "$run_output" ]; then
		printf 'FAIL Rust C ABI produced unexpected output: %s\n' "$run_output" >&2
		exit 1
	fi
	printf 'PASS Rust C ABI: binary and empty buffers, ownership, limits, all omission masks, directory apply\n'
else
	printf 'FAIL Rust C ABI runtime: %s\n' "$run_output" >&2
	exit 1
fi

case "$rust_host" in
	*-linux-*)
		if dependencies=$(readelf -d "$product/rust-caller" 2>&1); then :; else
			printf 'FAIL inspect Rust executable dependencies: %s\n' "$dependencies" >&2
			exit 1
		fi
		if printf '%s\n' "$dependencies" | awk '/NEEDED/ {print $NF}' | grep -Ei 'lib(difz|zstd|pcre2)'; then
			printf 'FAIL Rust executable requires a separate codec library\n' >&2
			exit 1
		fi
		printf 'PASS Rust executable has no dynamic difz, zstd, or PCRE2 dependency\n'
		;;
	aarch64-apple-darwin)
		if dependencies=$(otool -L "$product/rust-caller" 2>&1); then :; else
			printf 'FAIL inspect Rust executable dependencies: %s\n' "$dependencies" >&2
			exit 1
		fi
		if printf '%s\n' "$dependencies" | grep -Ei 'lib(difz|zstd|pcre2).*dylib'; then
			printf 'FAIL Rust executable requires a separate codec library\n' >&2
			exit 1
		fi
		printf 'PASS Rust executable has no dynamic difz, zstd, or PCRE2 dependency\n'
		;;
esac
