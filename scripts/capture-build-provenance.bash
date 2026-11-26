#!/usr/bin/env bash
# Capture Git history outside pure Nix, against the exact source Nix will build.
# The caller retains this record as an external nonflake input.
set -euo pipefail
[ "$#" -eq 2 ] || { printf 'usage: capture-build-provenance ROOT METADATA-JSON\n' >&2; exit 2; }
root=$1 metadata=$2
unavailable() {
	jq -cn --arg reason "$1" '{schema:"build-provenance/v1",available:false,reason:$reason}'
	exit 0
}
valid_hash() { [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]; }
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_SHALLOW_FILE GIT_REPLACE_REF_BASE GIT_NAMESPACE GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_EXEC_PATH || true
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_ATTR_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0
root=$(cd "$root" && pwd -P) || exit 1
git_read() { git -C "$root" -c core.attributesFile=/dev/null "$@"; }
[ "$(git_read rev-parse --show-toplevel 2>/dev/null)" = "$root" ] || unavailable missing-git-root
[ "$(git_read rev-parse --is-shallow-repository)" = false ] || unavailable incomplete-history
grafts=$(git_read rev-parse --path-format=absolute --git-path info/grafts) || unavailable unreadable-git-state
[ ! -s "$grafts" ] || unavailable grafted-history
commit=$(git_read rev-parse --verify HEAD) || unavailable missing-source-commit
tip=$(git_read rev-parse --verify refs/heads/yolo) || unavailable missing-primary-ref
valid_hash "$commit" && valid_hash "$tip" || unavailable invalid-commit
# Git archives cannot materialize submodules. Nix may treat these differently.
tree=$(git_read ls-tree -r "$commit") || unavailable incomplete-history
if printf '%s\n' "$tree" | grep -q '^160000 '; then unavailable unsupported-submodules; fi
history=$(git_read rev-list --first-parent "$tip") || unavailable incomplete-history
base=
while IFS= read -r candidate; do
	valid_hash "$candidate" || unavailable invalid-history
	if git_read merge-base --is-ancestor "$candidate" "$commit"; then base=$candidate; break
	else status=$?; [ "$status" -eq 1 ] || unavailable incomplete-history; fi
done <<< "$history"
[ -n "$base" ] || unavailable no-primary-ancestor
count=$(git_read rev-list --count "$base") || unavailable incomplete-history
[[ "$count" =~ ^[1-9][0-9]*$ ]] || unavailable invalid-primary-count
source_revision=$(jq -er '.locked.rev // .locked.dirtyRev | select(type == "string")' "$metadata") || unavailable missing-source-revision
[ "${source_revision%-dirty}" = "$commit" ] || unavailable source-commit-mismatch
source=$(jq -er '.path | select(type == "string" and startswith("/"))' "$metadata") || unavailable missing-source-path
nar=$(jq -er '.locked.narHash | select(type == "string")' "$metadata") || unavailable missing-source-nar
[[ "$nar" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || unavailable invalid-source-nar
[ "$(nix hash path "$source")" = "$nar" ] || unavailable source-hash-mismatch
work=$(mktemp -d "${TMPDIR:-/tmp}/difz-provenance.XXXXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/export"
git_read archive --format=tar "$commit" | tar -xf - -C "$work/export" || unavailable export-failed
export_hash=$(nix hash path "$work/export") || unavailable export-hash-failed
state=$(git_read status --porcelain=v1 --untracked-files=no) || unavailable unreadable-worktree
dirty=false
[ -z "$state" ] || dirty=true
if [ "$export_hash" != "$nar" ]; then
	# A clean source must match its commit export. Do not label unexplained
	# export filtering or source disagreement as an ordinary dirty build.
	[ -n "$state" ] || unavailable export-mismatch
	dirty=true
fi
# Resolve the Git-filtered source again. Changes after the original metadata
# capture must not be attested as part of that snapshot.
fresh=$(nix flake metadata --offline --no-update-lock-file --json "$root") || unavailable unreadable-source
[ "$(jq -er '.path' <<< "$fresh")" = "$source" ] && [ "$(jq -er '.locked.narHash' <<< "$fresh")" = "$nar" ] && \
	[ "$(jq -er '.locked.rev // .locked.dirtyRev' <<< "$fresh")" = "$source_revision" ] || unavailable source-changed
[ "$(git_read rev-parse --verify HEAD)" = "$commit" ] && [ "$(git_read rev-parse --verify refs/heads/yolo)" = "$tip" ] || unavailable history-changed
jq -cn --arg commit "$commit" --arg tip "$tip" --arg base "$base" \
	--arg nar "$nar" --arg revision "r$count-${commit:0:6}" --argjson count "$count" --argjson dirty "$dirty" \
	'{schema:"build-provenance/v1",available:true,source_commit:$commit,primary_ref:"refs/heads/yolo",primary_tip:$tip,primary_base:$base,primary_count:$count,source_nar_hash:$nar,dirty:$dirty,revision:$revision}'
