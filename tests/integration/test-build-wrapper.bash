#!/usr/bin/env bash
# Exercise the real selector/publisher with exact products and recording Nix I/O.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
zig_release=${1:?prepared Zig release required}; zig_debug=${2:?prepared Zig debug required}
rust_release=${3:?prepared Rust release required}; rust_debug=${4:?prepared Rust debug required}
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-build-wrapper.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
project="$work/project with spaces"
mkdir -p "$project/scripts" "$project/nix" "$work/tools" "$work/home" || exit 1
for entry in build run CANONICAL_IMPL; do cp "$root/$entry" "$project/$entry" || exit 1; done
for entry in build-driver.bash build-selection.bash verify-build-output.bash; do cp "$root/scripts/$entry" "$project/scripts/$entry" || exit 1; done
cp "$root/nix/build-targets.tsv" "$project/nix/build-targets.tsv" || exit 1
source "$root/scripts/build-selection.bash"
difz_build_load "$project" || exit 1
host=$(difz_build_normalize_host "$(uname -s)" "$(uname -m)") || exit 1
case "$host" in linux-amd64) system=x86_64-linux; zv=musl;; linux-arm64) system=aarch64-linux; zv=musl;; macos-arm64) system=aarch64-darwin; zv=-;; *) exit 1;; esac
rv=-; case "$host" in linux-*) rv=musl;; esac
zig_relative="zig-out/$host/ReleaseFast"; [ "$zv" = - ] || zig_relative="zig-out/$host/$zv/ReleaseFast"
rust_relative="rust-out/$host/release"; [ "$rv" = - ] || rust_relative="rust-out/$host/$rv/release"
public="$project/bin/$host/difz"
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/config" XDG_DATA_HOME="$work/home/data" XDG_STATE_HOME="$work/home/state" XDG_CACHE_HOME="$work/home/cache" XDG_RUNTIME_DIR="$work/home/runtime"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" || exit 1
export DIFZ_TEST_CALLS="$work/calls" DIFZ_TEST_COMPILER="$work/compiler" DIFZ_TEST_SNAPSHOT="$work/snapshot"
export DIFZ_TEST_ZIG_RELEASE="$zig_release" DIFZ_TEST_ZIG_DEBUG="$zig_debug" DIFZ_TEST_RUST_RELEASE="$rust_release" DIFZ_TEST_RUST_DEBUG="$rust_debug" DIFZ_TEST_SYSTEM="$system"
export DIFZ_TEST_RETAIN_FAILED="$work/retain-failed"
printf '/fixture/source-a' > "$DIFZ_TEST_SNAPSHOT"
for tool in zig cargo rustc; do
	printf '#!%s\ntouch "$DIFZ_TEST_COMPILER"\nexit 65\n' "$BASH" > "$work/tools/$tool" || exit 1
	chmod +x "$work/tools/$tool" || exit 1
done
# Start with a PATH containing ordinary utilities but no Nix.
for tool in bash dirname wc cmp; do ln -s "$(command -v "$tool")" "$work/tools/$tool" || exit 1; done
run_build() { (cd "$work" && PATH="$work/tools:$PATH" bash "$project/build" "$@") > "$work/out" 2> "$work/err"; }
for profile in default debug; do
	args=(); [ "$profile" = default ] || args=(debug)
	PATH="$work/tools" "$BASH" "$project/build" "${args[@]}" > "$work/out" 2> "$work/err"
	[ "$?" -eq 69 ] && [ ! -e "$DIFZ_TEST_COMPILER" ] && [ ! -e "$project/bin" ] || { cat "$work/err" >&2; exit 1; }
	grep -Fq 'Nix is required' "$work/err" || exit 1
done
printf '#!%s\n' "$BASH" > "$work/tools/nix"
cat >> "$work/tools/nix" <<'NIX'
set -u
printf '%s\n' "$@" >> "$DIFZ_TEST_CALLS"
operation=$1; shift
case "$operation" in
 develop)
  while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
  [ "$#" -gt 0 ] || exit 70; shift; exec "$@";;
 flake)
  [ "$1" = metadata ] || exit 71
  jq -n --arg path "$(cat "$DIFZ_TEST_SNAPSHOT")" '{path:$path}';;
 build)
  json=0; link=; targets=()
  while [ "$#" -gt 0 ]; do
   case "$1" in --json) json=1;; --out-link) shift; link=${1:-};; --no-update-lock-file|--offline|--refresh) :;; *) targets+=("$1");; esac
   shift
  done
  [ -n "$link" ] && [ "${#targets[@]}" -gt 0 ] || exit 72
  if [ "$json" -eq 1 ] && [ "${DIFZ_TEST_BUILD_STATUS:-0}" -ne 0 ]; then exit "$DIFZ_TEST_BUILD_STATUS"; fi
  if [ "$json" -eq 1 ] && [ "${DIFZ_TEST_OVERRIDE_SET:-0}" -eq 1 ]; then
   jq -n --arg prefix "${DIFZ_TEST_OVERRIDE:-}" '[{outputs:{out:$prefix}}]'; exit "$?"
  fi
  prefixes=()
  for target in "${targets[@]}"; do
   case "$target" in
    ".#packages.$DIFZ_TEST_SYSTEM.zig-release") prefix=$DIFZ_TEST_ZIG_RELEASE;;
    ".#packages.$DIFZ_TEST_SYSTEM.zig-debug") prefix=$DIFZ_TEST_ZIG_DEBUG;;
    ".#packages.$DIFZ_TEST_SYSTEM.rust-product") prefix=$DIFZ_TEST_RUST_RELEASE;;
    ".#packages.$DIFZ_TEST_SYSTEM.rust-product-debug") prefix=$DIFZ_TEST_RUST_DEBUG;;
    /*) prefix=$target;;
    *) exit 73;;
   esac
   prefixes+=("$prefix")
   index=$((${#prefixes[@]} - 1)); destination=$link
   [ "$index" -eq 0 ] || destination="$link-$index"
   temporary="$destination.next-$$"
   ln -s -- "$prefix" "$temporary" && mv -Tf -- "$temporary" "$destination" || exit 74
  done
  if [ "$json" -eq 0 ] && [ "${DIFZ_TEST_FAIL_RETAIN:-0}" -eq 1 ] && [[ "$link" = */rust-out/* ]] && [ ! -e "$DIFZ_TEST_RETAIN_FAILED" ]; then
   touch "$DIFZ_TEST_RETAIN_FAILED"; exit 75
  fi
  if [ "$json" -eq 1 ]; then
   printf '%s\n' "${prefixes[@]}" | jq -Rsc 'split("\n")[:-1] | map({outputs:{out:.}})'
   if [ "${DIFZ_TEST_CHANGE_SOURCE:-0}" -eq 1 ]; then printf '/fixture/source-b' > "$DIFZ_TEST_SNAPSHOT"; fi
  fi;;
 *) exit 76;;
esac
NIX
chmod +x "$work/tools/nix" || exit 1
printf '#!%s\n[ "${1:-}" = --check-validity ] && [ "$#" -eq 2 ]\n' "$BASH" > "$work/tools/nix-store" || exit 1
chmod +x "$work/tools/nix-store" || exit 1
for profile in default debug; do
	args=(--offline); [ "$profile" = default ] || args=(debug --offline)
	run_build "${args[@]}" || { cat "$work/err" >&2; exit 1; }
	[ -L "$public" ] && [ ! -e "$DIFZ_TEST_COMPILER" ] || exit 1
	"$public" --lang en --about > "$work/about" 2> "$work/about-err" || exit 1
done
# Existing alternate-prefix coverage now verifies links rather than copying.
mkdir -p "$work/alternate product" || exit 1
for entry in bin lib include; do ln -s "$zig_release/$entry" "$work/alternate product/$entry" || exit 1; done
export DIFZ_TEST_ZIG_RELEASE="$work/alternate product"
run_build --print-path || { cat "$work/err" >&2; exit 1; }
[ "$(cat "$work/out")" = "$public" ] && [ "$(readlink "$project/$zig_relative")" = "$work/alternate product" ] || exit 1
before=$(readlink "$public")
export DIFZ_TEST_BUILD_STATUS=23
if run_build; then printf 'FAIL forced Nix build failure passed\n' >&2; exit 1; fi
unset DIFZ_TEST_BUILD_STATUS
[ "$(readlink "$public")" = "$before" ] && [ "$(readlink "$project/$zig_relative")" = "$work/alternate product" ] || exit 1
for shape in missing directory nonexecutable empty multiple; do
	prefix="$work/invalid-$shape"
	mkdir -p "$prefix/bin" || exit 1
	ln -s "$zig_release/lib" "$prefix/lib" || exit 1
	ln -s "$zig_release/include" "$prefix/include" || exit 1
	case "$shape" in missing) :;; directory) mkdir "$prefix/bin/difz";; nonexecutable) printf plain > "$prefix/bin/difz";; empty) prefix=;; multiple) prefix="$zig_release"$'\n'"$rust_release";; esac
	export DIFZ_TEST_OVERRIDE_SET=1 DIFZ_TEST_OVERRIDE="$prefix"
	if run_build; then printf 'FAIL invalid artifact shape %s accepted\n' "$shape" >&2; exit 1; fi
	[ "$(readlink "$public")" = "$before" ] && [ "$(readlink "$project/$zig_relative")" = "$work/alternate product" ] || exit 1
done
unset DIFZ_TEST_OVERRIDE_SET DIFZ_TEST_OVERRIDE
if run_build --out-link "$work/custom link"; then printf 'FAIL unmanaged output override accepted\n' >&2; exit 1; fi
[ "$(readlink "$public")" = "$before" ] || exit 1
calls=$(wc -c < "$DIFZ_TEST_CALLS")
PATH="$work/tools:$PATH" bash "$project/build" canonize rust > "$work/canonized" 2> "$work/canonize-errors" || exit 1
[ "$(wc -c < "$DIFZ_TEST_CALLS")" -eq "$calls" ] && [ "$(readlink "$public")" = "$before" ] || exit 1
run_build --all-impls || { cat "$work/err" >&2; exit 1; }
[ "$(readlink "$public")" = "../../$rust_relative/bin/difz" ] && [ -L "$project/$zig_relative" ] && [ -L "$project/$rust_relative" ] || exit 1
[ -L "$project/.build-state/previous/$host/product" ] || exit 1
for profile in default debug; do
	args=(); [ "$profile" = default ] || args=(--debug)
	run_build "${args[@]}" || { cat "$work/err" >&2; exit 1; }
done
run_build || exit 1
before=$(readlink "$public"); old_prefix=$(readlink "$project/$rust_relative")
mkdir -p "$work/alternate rust product" || exit 1
for entry in bin lib include nix-support; do ln -s "$rust_release/$entry" "$work/alternate rust product/$entry" || exit 1; done
export DIFZ_TEST_RUST_RELEASE="$work/alternate rust product" DIFZ_TEST_FAIL_RETAIN=1
if run_build; then printf 'FAIL failed retention registration passed\n' >&2; exit 1; fi
unset DIFZ_TEST_FAIL_RETAIN
[ "$(readlink "$public")" = "$before" ] && [ "$(readlink "$project/$rust_relative")" = "$old_prefix" ] || { cat "$work/err" >&2; exit 1; }
export DIFZ_TEST_CHANGE_SOURCE=1
if run_build; then printf 'FAIL source change during build passed\n' >&2; exit 1; fi
unset DIFZ_TEST_CHANGE_SOURCE
printf '/fixture/source-a' > "$DIFZ_TEST_SNAPSHOT"
[ "$(readlink "$public")" = "$before" ] && [ "$(readlink "$project/$rust_relative")" = "$old_prefix" ] || exit 1
mkdir "$project/.build-state/publish.lock" || exit 1
if run_build; then printf 'FAIL competing publisher lock ignored\n' >&2; exit 1; fi
rmdir "$project/.build-state/publish.lock" || exit 1
[ "$(readlink "$public")" = "$before" ] || exit 1
[ ! -e "$DIFZ_TEST_COMPILER" ] || exit 1
# Development launch resolves this checkout's selected product, preserving argv
# and the CLI's exit status instead of consulting an installed PATH command.
PATH="$work/tools:$PATH" bash "$project/run" --lang en --about > "$work/run-about" 2> "$work/run-errors" || { cat "$work/run-errors" >&2; exit 1; }
"$public" --lang en --about > "$work/direct-about" || exit 1
cmp "$work/run-about" "$work/direct-about" || exit 1
PATH="$work/tools:$PATH" bash "$project/run" --unknown-build-contract-option > "$work/run-out" 2> "$work/run-err"
run_status=$?
"$public" --unknown-build-contract-option > "$work/direct-out" 2> "$work/direct-err"
direct_status=$?
[ "$run_status" -ne 0 ] && [ "$run_status" -eq "$direct_status" ] || { printf 'FAIL development launch status: %s versus %s\n' "$run_status" "$direct_status" >&2; cat "$work/run-err" "$work/direct-err" >&2; exit 1; }
# Unknown entrypoints and symlinked publication parents are owner data. Reject
# them before compilation, and leave both the sentinel and managed link intact.
mv "$public" "$work/managed-command" || exit 1
printf 'owner command\n' > "$public" || exit 1
if run_build; then printf 'FAIL unknown command file replaced\n' >&2; exit 1; fi
[ "$(cat "$public")" = 'owner command' ] || exit 1
rm "$public" && ln -s "$work/owner-link" "$public" || exit 1
if run_build; then printf 'FAIL unknown command link replaced\n' >&2; exit 1; fi
[ "$(readlink "$public")" = "$work/owner-link" ] || exit 1
rm "$public" && mv "$work/managed-command" "$public" || exit 1
mv "$project/bin/$host" "$work/owned-bin" && ln -s "$work/owned-bin" "$project/bin/$host" || exit 1
if run_build; then printf 'FAIL symlinked publication parent accepted\n' >&2; exit 1; fi
[ "$(readlink "$work/owned-bin/difz")" = "$before" ] || exit 1
rm "$project/bin/$host" && mv "$work/owned-bin" "$project/bin/$host" || exit 1
[ ! -e "$DIFZ_TEST_COMPILER" ] || exit 1
printf 'PASS build publisher: required Nix, four products/profiles, exact links, alternate paths, invalid artifacts, rollback, locking, exact development launch and preservation of unknown commands/parents\n'
