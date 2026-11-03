#!/usr/bin/env bash
# Exercise the real build adapter in a disposable project with controlled builders.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
scratch=$(mktemp -d "${TMPDIR:-/tmp}/difz-build-wrapper.XXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
bash_bin=$(command -v bash) || exit 1
mkdir -p "$scratch/tools" "$scratch/project/result/bin" || exit 1
cp "$root/build" "$scratch/project/build" || exit 1
for tool in mkdir install; do
	tool_path=$(command -v "$tool") || exit 1
	ln -s "$tool_path" "$scratch/tools/$tool" || exit 1
done
# The child builder expands these variables at invocation, not fixture creation.
# shellcheck disable=SC2016
printf '#!%s\nprintf "called\\n" > "$BUILDER_MARKER"\nexit 0\n' "$bash_bin" > "$scratch/tools/zig" || exit 1
chmod +x "$scratch/tools/zig" || exit 1
printf 'prepared executable\n' > "$scratch/project/result/bin/difz" || exit 1
chmod +x "$scratch/project/result/bin/difz" || exit 1
export BUILDER_MARKER="$scratch/zig-called" NIX_ARGUMENTS="$scratch/nix-arguments"
export NIX_PREFIX="$scratch/project/result"
export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data"
export XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" XDG_RUNTIME_DIR="$scratch/runtime"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" || exit 1
chmod 700 "$XDG_RUNTIME_DIR" || exit 1
run_build() {
	(cd "$scratch/project" && PATH="$scratch/tools" "$bash_bin" ./build "$@") > "$scratch/output" 2>&1
}
for profile in default debug; do
	args=()
	if [ "$profile" = debug ]; then args=(debug); fi
	run_build "${args[@]}"
	status=$?
	if [ "$status" -ne 69 ] || [ -e "$BUILDER_MARKER" ] || [ -e "$scratch/project/zig-out" ]; then
		printf 'FAIL missing Nix must refuse %s without executing Zig or publishing\n' "$profile" >&2
		cat "$scratch/output" >&2
		exit 1
	fi
	grep -Fq 'Nix is required' "$scratch/output" || exit 1
done
# Arguments and injected results belong to each later builder invocation.
# shellcheck disable=SC2016
printf '#!%s\nprintf "%%s\\n" "$@" > "$NIX_ARGUMENTS"\nprintf "%%s\\n" "$NIX_PREFIX"\nexit "${NIX_STATUS:-0}"\n' "$bash_bin" > "$scratch/tools/nix" || exit 1
chmod +x "$scratch/tools/nix" || exit 1
for profile in default debug; do
	args=()
	if [ "$profile" = debug ]; then args=(debug); fi
	if ! run_build "${args[@]}" --offline; then cat "$scratch/output" >&2; exit 1; fi
	printf 'build\n--no-update-lock-file\n--print-out-paths\n.#%s\n--offline\n' "$profile" > "$scratch/expected-arguments" || exit 1
	cmp "$scratch/expected-arguments" "$NIX_ARGUMENTS" || exit 1
	cmp "$scratch/project/result/bin/difz" "$scratch/project/zig-out/bin/difz" || exit 1
	[ ! -e "$BUILDER_MARKER" ] || exit 1
done
mkdir -p "$scratch/alternate output/bin" || exit 1
printf 'selected alternate executable\n' > "$scratch/alternate output/bin/difz" || exit 1
chmod +x "$scratch/alternate output/bin/difz" || exit 1
export NIX_PREFIX="$scratch/alternate output"
if ! run_build --out-link "$scratch/custom link"; then cat "$scratch/output" >&2; exit 1; fi
cmp "$scratch/alternate output/bin/difz" "$scratch/project/zig-out/bin/difz" || exit 1
export NIX_PREFIX="$scratch/project/result"
printf 'existing selection\n' > "$scratch/project/zig-out/bin/difz" || exit 1
cp "$scratch/project/zig-out/bin/difz" "$scratch/previous" || exit 1
export NIX_STATUS=23
if run_build; then printf 'FAIL failed Nix build must fail\n' >&2; exit 1; fi
cmp "$scratch/previous" "$scratch/project/zig-out/bin/difz" || exit 1
unset NIX_STATUS
for shape in missing directory nonexecutable empty multiple; do
	export NIX_PREFIX="$scratch/invalid-$shape"
	mkdir -p "$NIX_PREFIX/bin" || exit 1
	case "$shape" in
		missing) ;;
		directory) mkdir "$NIX_PREFIX/bin/difz" || exit 1 ;;
		nonexecutable) printf 'not executable\n' > "$NIX_PREFIX/bin/difz" || exit 1 ;;
		empty) NIX_PREFIX='' ;;
		multiple) printf -v NIX_PREFIX '%s\n%s' "$scratch/project/result" "$scratch/alternate output" ;;
		*) exit 1 ;;
	esac
	if run_build; then printf 'FAIL invalid Nix artifact must fail: %s\n' "$shape" >&2; exit 1; fi
	cmp "$scratch/previous" "$scratch/project/zig-out/bin/difz" || exit 1
done
[ ! -e "$BUILDER_MARKER" ] || exit 1
printf 'PASS build adapter: required Nix, two profiles, exact artifact selection, failed build, five invalid artifact shapes\n'
