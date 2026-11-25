#!/usr/bin/env bash
# Real GC-root/publication operations use an entirely private local Nix store.
# The native product was built once by the enclosing check's dependency graph.
set -u
product=${1:?prepared native product required}
root=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
real_nix=$(command -v nix) || exit 1
real_nix_store=$(command -v nix-store) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-private-nix-roots.XXXXXXXX") || exit 1
trap 'if [ -d "$work/store" ]; then chmod -R u+w -- "$work/store"; fi; rm -rf -- "$work"' EXIT
project="$work/project with spaces"
mkdir -p "$project/scripts" "$project/nix" "$work/tools" "$work/home" "$work/conf" || exit 1
for entry in build CANONICAL_IMPL; do cp "$root/$entry" "$project/$entry" || exit 1; done
for entry in build-driver.bash build-selection.bash verify-build-output.bash; do cp "$root/scripts/$entry" "$project/scripts/$entry" || exit 1; done
cp "$root/nix/build-targets.tsv" "$project/nix/build-targets.tsv" || exit 1
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/config" XDG_DATA_HOME="$work/home/data" XDG_STATE_HOME="$work/home/state" XDG_CACHE_HOME="$work/home/cache" XDG_RUNTIME_DIR="$work/home/runtime"
export NIX_STORE_DIR="$work/store" NIX_STATE_DIR="$work/state" NIX_LOG_DIR="$work/log" NIX_CONF_DIR="$work/conf" NIX_REMOTE=local
export NIX_CONFIG=$'experimental-features = nix-command flakes\nbuild-users-group =\nsubstituters =\n'
"$real_nix_store" --init || exit 1
private_product=$("$real_nix" store add --name difz-native-fixture "$product") || exit 1
case "$private_product" in "$work/store/"*) :;; *) printf 'FAIL fixture did not use the private Nix store\n' >&2; exit 1;; esac
export DIFZ_PRIVATE_NIX="$real_nix" DIFZ_PRIVATE_PRODUCT="$private_product"
printf '#!%s\n' "$BASH" > "$work/tools/nix"
cat >> "$work/tools/nix" <<'NIX'
set -u
operation=$1; shift
case "$operation" in
 develop)
  while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
  [ "$#" -gt 0 ] || exit 65; shift; exec "$@";;
 flake) printf '{"path":"/immutable/prepared/source"}\n';;
 build)
  # Compilation is already complete; only the flake selector is substituted.
  # Root creation/registration/realization below uses the real Nix executable.
  arguments=(); preparation=0
  for argument in "$@"; do
   case "$argument" in .#*) arguments+=("$DIFZ_PRIVATE_PRODUCT"); preparation=1;; *) arguments+=("$argument");; esac
  done
  if [ "$preparation" -eq 1 ]; then
   result=$("$DIFZ_PRIVATE_NIX" build "${arguments[@]}") || exit "$?"
   # Opaque-path JSON is an array of strings; flake-package JSON contains
   # output objects. Normalize only this prepared-artifact test adapter.
   jq 'map(if type == "string" then {outputs:{out:.}} else . end)' <<< "$result"
  else exec "$DIFZ_PRIVATE_NIX" build "${arguments[@]}"; fi;;
 *) exit 66;;
esac
NIX
chmod +x "$work/tools/nix" || exit 1
PATH="$work/tools:$PATH" bash "$project/build" --print-path > "$work/published" 2> "$work/errors"
status=$?
if [ "$status" -ne 0 ]; then cat "$work/errors" >&2; exit 1; fi
public=$(cat "$work/published") || exit 1
case "$public" in "$project/bin/"*/difz) :;; *) exit 1;; esac
[ -L "$public" ] || exit 1
relative=$(readlink "$public") || exit 1
product_relative=${relative#../../}; product_relative=${product_relative%/bin/difz}
retained="$project/$product_relative"
[ "$(readlink "$retained")" = "$private_product" ] || exit 1
roots=$("$real_nix_store" --gc --print-roots) || exit 1
printf '%s\n' "$roots" | grep -Fq "$retained" || { printf 'FAIL final product is not a registered GC root\n' >&2; exit 1; }
"$public" --lang en --about > "$work/about" 2> "$work/about-errors" || exit 1
PATH="$work/tools:$PATH" bash "$project/build" > "$work/out" 2> "$work/errors" || { cat "$work/errors" >&2; exit 1; }
[ -L "$project/.build-state/previous/$(basename "$(dirname "$public")")/product" ] || exit 1
[ -z "$(ls -A "$project/.build-work")" ] || { printf 'FAIL publication left temporary transaction data\n' >&2; exit 1; }
printf 'PASS real Nix publication: private store, exact prepared native product, registered final roots, direct launch, previous product and transaction cleanup\n'
