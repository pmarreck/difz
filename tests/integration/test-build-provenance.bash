#!/usr/bin/env bash
set -euo pipefail
collector=${1:?collector required}
work=$(mktemp -d "${TMPDIR:?}/difz-local-provenance.XXXXXXXX")
trap 'if [ -d "$work/store" ]; then chmod -R u+w -- "$work/store"; fi; rm -rf -- "$work"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export NIX_REMOTE=local NIX_STORE_DIR="$work/store" NIX_STATE_DIR="$work/state" NIX_LOG_DIR="$work/log" NIX_CONF_DIR="$work/conf"
export NIX_CONFIG=$'experimental-features = nix-command flakes\nbuild-users-group =\nsubstituters =\n'
mkdir -p "$work/conf"
nix-store --init
git init -q -b yolo "$work/repo"
g() { git -C "$work/repo" "$@"; }
commit() { printf '%s\n' "$1" > "$work/repo/$1"; g add "$1"; g commit -qm "$1"; }
printf '%s\n' '{ outputs = { self }: {}; }' > "$work/repo/flake.nix"
g add flake.nix
commit root
g switch -qc merged-topic
commit merged-one
commit merged-two
g switch -q yolo
commit primary-one
g merge -q --no-ff merged-topic -m merge-topic
base=$(g rev-parse HEAD)
[ "$(g rev-list --count "$base")" -eq 5 ]
[ "$(g rev-list --first-parent --count "$base")" -eq 3 ]
g switch -qc unmerged-topic
commit topic-one
commit topic-two
built=$(g rev-parse HEAD)
g switch -q yolo
commit later-primary
tip=$(g rev-parse HEAD)
g switch -q unmerged-topic
capture_metadata() { nix flake metadata --offline --no-update-lock-file --json "$work/repo" > "$work/metadata"; }
run() { bash "$collector" "$work/repo" "$work/metadata"; }
capture_metadata
record=$(run)
jq -e --arg base "$base" --arg tip "$tip" --arg built "$built" '.available and .primary_tip == $tip and .primary_base == $base and .source_commit == $built and .primary_count == 5 and .dirty == false and .revision == ("r5-" + $built[0:6])' <<< "$record" > /dev/null
# Untracked envelopes are excluded from the Git-filtered built source.
printf private > "$work/repo/untracked-note"
capture_metadata
[ "$(run)" = "$record" ]
printf dirty >> "$work/repo/root"
capture_metadata
run | jq -e --arg revision "$(jq -r .revision <<< "$record")" '.available and .dirty == true and .revision == $revision' > /dev/null
printf stale >> "$work/repo/root"
run | jq -e '.available == false and .reason == "source-changed"' > /dev/null
g restore root
capture_metadata
contaminated=$(GIT_DIR="$work/missing" GIT_INDEX_FILE="$work/absent-index" GIT_SHALLOW_FILE="$work/absent-shallow" GIT_NAMESPACE=missing run)
[ "$contaminated" = "$record" ]
# Empty commits share source bytes/NAR. Their full source identity must still
# agree with the original Nix metadata rather than silently relabeling a build.
g commit -q --allow-empty -m identical-tree-new-commit
run | jq -e '.available == false and .reason == "source-commit-mismatch"' > /dev/null
g switch -q --detach "$built"
capture_metadata
[ "$(run)" = "$record" ]
git clone -q --depth=1 "file://$work/repo" "$work/shallow"
bash "$collector" "$work/shallow" "$work/metadata" | jq -e '.available == false and .reason == "incomplete-history"' > /dev/null
jq '.locked.narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' "$work/metadata" > "$work/wrong-nar"
bash "$collector" "$work/repo" "$work/wrong-nar" | jq -e '.available == false and .reason == "source-hash-mismatch"' > /dev/null
bash "$collector" "$work" "$work/metadata" | jq -e '.available == false and .reason == "missing-git-root"' > /dev/null
printf 'PASS source-bound collector: real Git/Nix snapshots, merged ancestry, topic base/count, excluded untracked data, separate dirty revision, stale source, same-tree commit mismatch, sanitized Git environment, shallow and wrong-NAR controls\n'
