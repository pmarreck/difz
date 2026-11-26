#!/usr/bin/env bash
# Test-only ARM64 execution in a private interpreter registry, never the host's.
set -uo pipefail
fail() { printf 'FAIL private ARM64 execution: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 3 ]] || fail 'expected QEMU, an ARM64 ELF probe, and a command'
qemu=$1 probe=$2
shift 2
[[ -f $qemu && -x $qemu && -f $probe && -x $probe ]] || fail 'missing prepared interpreter or probe'
case "$qemu" in /nix/store/*/bin/qemu-aarch64) :;; *) fail 'interpreter must be a pinned QEMU binary';; esac
unshare_tool=$(type -P unshare) || fail 'missing unshare'
mount_tool=$(type -P mount) || fail 'missing mount'
for tool in "$unshare_tool" "$mount_tool"; do
	case "$tool" in /nix/store/*) :;; *) fail 'namespace tools must come from Nix';; esac
done
tag=difz-test-aarch64
[[ ! -e /proc/sys/fs/binfmt_misc/$tag ]] || fail 'the parent already has this registry entry'
parent_user=$(readlink /proc/self/ns/user) || fail 'parent user namespace'
parent_mount=$(readlink /proc/self/ns/mnt) || fail 'parent mount namespace'
status=0
"$unshare_tool" --user --map-root-user --mount --pid --fork --kill-child --mount-proc --propagation private \
	bash -c '
		set -uo pipefail
		fail() { printf "FAIL private ARM64 execution: %s\n" "$*" >&2; exit 1; }
		parent_user=$1 parent_mount=$2 mount_tool=$3 qemu=$4 probe=$5 tag=$6
		shift 6
		[[ $(id -u) == 0 && $$ == 1 ]] || fail "private user/PID namespace missing"
		[[ $(readlink /proc/self/ns/user) != "$parent_user" && $(readlink /proc/self/ns/mnt) != "$parent_mount" ]] || fail "namespace isolation missing"
		work=$(mktemp -d "${TMPDIR:?}/difz-arm64-namespace.XXXXXXXX") || fail "private scratch"
		mkdir "$work/registry" || fail "private registry mountpoint"
		"$mount_tool" -t binfmt_misc none "$work/registry" || fail "private binfmt mount unavailable"
		probe_status=0
		"$probe" --version > "$work/unregistered.out" 2> "$work/unregistered.err" || probe_status=$?
		[[ $probe_status == 126 ]] || fail "empty private registry did not reject ARM64 ELF; exit=$probe_status"
		printf "%s\n" ":$tag:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:$qemu:F" > "$work/registry/register" || fail "private interpreter registration"
		[[ -r $work/registry/$tag ]] || fail "private entry absent"
		printf "PASS isolated ARM64 registry; unregistered ELF rejected\n"
		exec "$@"
	' private-arm64 "$parent_user" "$parent_mount" "$mount_tool" "$qemu" "$probe" "$tag" "$@" || status=$?
[[ ! -e /proc/sys/fs/binfmt_misc/$tag ]] || fail 'registry entry escaped into the parent'
exit "$status"
