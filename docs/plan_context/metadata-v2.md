# DIFZTREE v2 metadata

Peter, 2026-09-29: difz must cover xattrs, ACLs, timestamps, Finder flags, sparse extents, and hardlink identity in a platform-agnostic way. Restore of a foreign OS is best-effort. Applying a Windows ACL on Linux or macOS warns rather than pretending the native form landed. Create can omit families (`--omit-metadata acl,xattr`) so a patch never carries data the destination cannot represent.

v1 stays valid. v1 identity (`DIFZTREE-ID\x01`) ignores metadata. A snapshot that carries any of these families, or a hardlink entry, is v2 (`DIFZTREE-ID\x02`).

## What is in the identity

Canonical, sorted records:

- logical and raw extended attributes (names and values)
- portable ACL entries (owner, group, everyone, named user, named group, mask; read/write/execute) plus an optional native blob tagged with its origin OS
- mtime and birth time as signed seconds plus nanoseconds
- Finder info (32 bytes) and BSD flags
- sparse hole list (offset, length) while the file payload remains the logical bytes, holes included as zeros
- hardlink entries whose payload is the canonical path of the first file with those bytes

ctime is not recorded. Userspace cannot set it, so after apply it means the apply time. atime is not captured: a second read under relatime would make two snapshots of one tree hash differently. Owner and group ids stay out of this slice.

`xattr_stream` owns logical-name transfer. Logical names are the cross-OS xattr path and restore with no compromise warning (Peter, 2026-09-29). `com.apple.*` is not a logical name; it is raw or, for Finder info, the typed field. Raw names the target cannot store are preserved in `difz.raw-xattrs` with one warning. Names `difz.mtime`, `difz.btime`, `difz.finder-info`, `difz.bsd-flags`, `difz.native-acl`, `difz.portable-acl`, `difz.sparse-holes`, `difz.hardlink-to`, and `difz.raw-xattrs` are transport sidecars, not user attributes.

## Last-modification time

Decision, 2026-09-29, on the open question: apply restores mtime.

The v2 hash includes it, and the staged tree has to match the publisher hash. tar, rsync -a, and dpkg restore the upstream stamp for the same reason. `--omit-metadata timestamps` drops mtime and birth time from the patch and the identity, and then there is no warning.

Apply sets mtime last, on the object itself, after bytes, xattrs, ACLs, and hole punches. Symlinks are updated without following them. A directory's mtime is set after its children exist. Hardlinked names share one stamp, set on the canonical file. A timestamp-only change uses `file_copy` (bytes taken from the source tree, empty payload) plus the metadata record.

Linux snapshot and apply do this for files, directories, and symlinks. The filesystem test checks the applied stamps with `stat`. When the reconstructed tree carries metadata, the staged-tree check uses the v2 hash. Birth time is not captured on this path yet.

Birth time is recorded. macOS and Windows set it natively. Linux writes `difz.btime` and warns once per apply. Capture prefers that sidecar over the kernel birth time.

When the volume's tick is coarser than the stored nanoseconds (NTFS 100 ns, exFAT 10 ms, HFS+ 1 s, FAT 2 s), apply keeps the value the volume stored, writes the original to `difz.mtime`, and warns once. Capture prefers the sidecar, so the staged hash still matches, and a later apply onto ext4, btrfs, xfs, or APFS can restore the original. Those four already store the nanoseconds directly, so the sidecar stays absent there.

## Omit

The patch header records the omit mask. Apply re-snapshots with the same mask, so an omitted family is absent from both sides of the identity check and produces no warning.

## Best-effort restore

Try the native operation. On success, do not leave a sidecar. On failure, write the sidecar and warn on stderr. The staged-tree check still requires the canonical record, which a later snapshot rebuilds from the native API or from the sidecar. If the sidecar cannot be written either, apply fails. That keeps "warning" from meaning "identity silently changed."

Mac deltas stay disabled until a supported bundle profile or post-stapling archive passes native checks. This layer does not make a reconstructed `.app` a Gatekeeper pass.
