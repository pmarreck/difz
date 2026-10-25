#!/usr/bin/env bash
# Invalid artifact sets must fail before any artifact or compiler is executed.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-prepared-runners.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
record="$work/executed"
mkdir -p "$work/tools" || exit 1
for tool in zig rustc cargo; do
	# shellcheck disable=SC2016
	printf '#!%s\nprintf called >> "$DIFZ_RUNNER_RECORD"\nexit 66\n' "$BASH" > "$work/tools/$tool" || exit 1
	chmod +x "$work/tools/$tool" || exit 1
done
export DIFZ_RUNNER_RECORD="$record"
export PATH="$work/tools:$PATH"
slots=(bin/difz libexec/difz-unit-tests bin/difz-rust-caller)
for cli in valid missing directory non-executable; do
	for core in valid missing directory non-executable; do
		for ffi in valid missing directory non-executable; do
			# The complete real suite supplies the all-valid positive control.
			[ "$cli,$core,$ffi" != valid,valid,valid ] || continue
			prefix="$work/prefix with spaces/$cli-$core-$ffi"
			mkdir -p "$prefix/bin" "$prefix/libexec" || exit 1
			shapes=("$cli" "$core" "$ffi")
			for index in 0 1 2; do
				path="$prefix/${slots[$index]}"
				case "${shapes[$index]}" in
					valid) ln -s "$work/tools/zig" "$path" || exit 1;;
					missing) :;;
					directory) mkdir "$path" || exit 1;;
					non-executable) printf plain > "$path" || exit 1;;
				esac
			done
			DIFZ_HOST_TESTS="$prefix" bash "$root/tests/run-prepared-host" > "$work/out" 2> "$work/err"
			status=$?
			if [ "$status" -eq 0 ] || [ -e "$record" ] || [ ! -s "$work/err" ]; then
				printf 'FAIL prepared artifact classification %s %s %s\n' "$cli" "$core" "$ffi" >&2
				exit 1
			fi
		done
	done
done
for shape in missing directory non-executable; do
	case "$shape" in
		missing) caller="$work/absent";;
		directory) caller="$work";;
		non-executable) caller="$work/plain"; printf plain > "$caller";;
	esac
	DIFZ_RUST_CALLER="$caller" bash "$root/tests/ffi/test_rust_lib.bash" > "$work/out" 2> "$work/err"
	status=$?
	if [ "$status" -eq 0 ] || [ -e "$record" ] || [ ! -s "$work/err" ]; then
		printf 'FAIL prepared Rust consumer classification %s\n' "$shape" >&2; exit 1
	fi
done
printf 'PASS prepared runners reject 63 invalid artifact sets and three invalid Rust paths without execution\n'
