# DIFZTREE v2 metadata

Accepted scope, 2026-09-29: difz must cover xattrs, ACLs, timestamps, Finder flags, sparse extents, and hardlink identity in a platform-agnostic way. Restore of a foreign OS is best-effort. Applying a Windows ACL on Linux or macOS warns rather than pretending the native form landed. Create can omit families (`--omit-metadata acl,xattr`) so a patch never carries data the destination cannot represent.

Decision, 2026-10-08: the project remains in break mode. DIFZTREE v2 is the only writer and reader path, including metadata-free snapshots; v1 is rejected. Every tree identity uses `DIFZTREE-ID\x02` and includes canonical metadata. No compatibility API or separate v1 identity remains.

## What is in the identity

Canonical, sorted records:

- logical and raw extended attributes (names and values)
- portable ACL entries (owner, group, everyone, named user, named group, mask; read/write/execute) plus an optional native blob tagged with its origin OS
- mtime and birth time as signed seconds plus nanoseconds
- Finder info (32 bytes) and BSD flags
- sparse hole list (offset, length) while the file payload remains the logical bytes, holes included as zeros
- hardlink entries whose payload names the first included path with the same filesystem identity and inode; equal bytes alone do not establish a link

ctime is not recorded. Userspace cannot set it, so after apply it means the apply time. atime is not captured: a second read under relatime would make two snapshots of one tree hash differently. Owner and group ids stay out of this slice.

`xattr_stream` owns logical-name transfer. Logical names are the cross-OS xattr path and restore with no compromise warning (decision, 2026-09-29). `com.apple.*` is not a logical name; it is raw or, for Finder info, the typed field. Raw names the target cannot store are preserved in `difz.raw-xattrs` with one warning. Names `difz.mtime`, `difz.btime`, `difz.finder-info`, `difz.bsd-flags`, `difz.native-acl`, `difz.portable-acl`, `difz.sparse-holes`, `difz.hardlink-to`, and `difz.raw-xattrs` are transport sidecars, not user attributes.

## Last-modification time

Decision, 2026-09-29, on the open question: apply restores mtime.

The v2 hash includes it, and the staged tree has to match the publisher hash. tar, rsync -a, and dpkg restore the upstream stamp for the same reason. `--omit-metadata timestamps` drops mtime and birth time from the patch and the identity, and then there is no warning.

Apply sets mtime last, on the object itself, after bytes, xattrs, ACLs, and hole punches. Symlinks are updated without following them. A directory's mtime is set after its children exist. Hardlinked names share one stamp, set on the canonical file. A timestamp-only change uses `file_copy` (bytes taken from the source tree, empty payload) plus the metadata record.

Linux snapshot and apply do this for files, directories, and symlinks. The filesystem test checks the applied stamps with `stat`. When the reconstructed tree carries metadata, the staged-tree check uses the v2 hash. Birth time is not captured on this path yet.

Birth time is recorded. macOS and Windows set it natively. Linux writes `difz.btime` and warns once per apply. Capture prefers that sidecar over the kernel birth time.

When the volume's tick is coarser than the stored nanoseconds (NTFS 100 ns, exFAT 10 ms, HFS+ 1 s, FAT 2 s), apply keeps the value the volume stored, writes the original to `difz.mtime`, and warns once. Capture prefers the sidecar, so the staged hash still matches, and a later apply onto ext4, btrfs, xfs, or APFS can restore the original. Those four already store the nanoseconds directly, so the sidecar stays absent there.

## Omit

`--omit-metadata` strips families before capture and hashing. The CLI accepts comma-separated lists of `xattr`, `acl`, `timestamps`, `finder`, `sparse`, and `hardlink`. The C boundary accepts the corresponding bit mask. An omitted family is absent from the patch and the identity and produces no warning. Apply reads the stored mask and uses it for both source capture and staged verification. All 64 subsets are tested against every family of source changes.

Header flag bit 0 (`0x1`) is unrelated. It is set only when the target snapshot root has metadata. The body then ends with a `u32` length and one canonical metadata record for that root. Bits 1 through 6 hold the omission mask in the family order above. Bits 7 through 31 are rejected, as are metadata payloads that contradict the mask. The source root is part of the source hash and is not stored: apply re-reads it from the source directory.

The snapshot root cannot be an entry. `validatePath` rejects an empty path. Gatekeeper looks at the directory the user opens (`Beamer.app`), so its attributes have to ride this trailer. `treeHashWithRoot` with an empty root equals `treeHash`. A non-empty root appends the domain `DIFZTREE-ROOT\x01` and the BLAKE3 of that canonical record.

## Extended attributes on disk

Snapshot and apply call `xattr_stream` with `follow_symlinks = false`. A name `fromNative` accepts is stored as logical, without a `user.` prefix. Anything else is raw, under the native name. `com.apple.ResourceFork` is skipped. So are `system.posix_acl_access` and `system.posix_acl_default`; those belong to the ACL family. Transport names are not captured again, except `difz.raw-xattrs`, which is decoded and merged back so a sidecar still hashes as the original raw attributes.

Logical names are set on apply. A failure there fails the apply. A raw name this OS rejects, or a raw set that returns permission or unsupported, is packed into `difz.raw-xattrs` with one stderr line. Values above 64 KiB fail the snapshot (`error.TooLarge`) rather than being dropped.

The filesystem root record is xattrs only. Root mtime, mode, and the other families are not captured on this path. Child mtimes are still written last, after content, permissions, and xattrs, because `setxattr` can bump mtime. The staged check hashes entries and the root record together.

The 2026-10-04 host tests cover a logical `comment` and a raw quarantine name on a file, and the same pair on the snapshot root, through create and apply. On macOS the root also carries `com.apple.provenance` and `com.apple.macl`. The quarantine name is `com.apple.quarantine` there and `user.com.apple.quarantine` on Linux. Writing a quarantine attribute that was not on the source is not part of this path.

`./test` requires the host filesystem metadata suite as well as the Nix checks. It sets `DIFZ_REQUIRE_XATTR_TESTS=1` for the host run, so unsupported xattrs fail the complete entry point. In the Nix sandbox, a filesystem without xattrs reports those cases as skipped rather than silently passing them. The host run supplies the required real-adapter assertions; pure patch tests also run in the sandbox.

## Best-effort restore

Try the native operation. On success, do not leave a sidecar. On failure, write the sidecar and warn on stderr. The staged-tree check still requires the canonical record, which a later snapshot rebuilds from the native API or from the sidecar. If the sidecar cannot be written either, apply fails. That keeps "warning" from meaning "identity silently changed."

Decision, 2026-10-08: when a symlink cannot store metadata natively, preserve the unsupported fields in a transport attribute on its parent directory. Readback must recover the original canonical symlink metadata, and apply must report a compromise warning. A transport failure fails apply; omitted families stay absent and produce no warning. Implementation of this transport remains in PLAN.md.

The 2026-10-01 archive measurement covers a ditto zip of an already-signed app, not this metadata layer. A reconstructed `.app` tree is still not a Gatekeeper pass.
