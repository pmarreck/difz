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

Snapshot and apply cover files, directories, symlinks, and the snapshot root. Filesystem tests check applied stamps with `stat`, and the staged-tree check always uses the v2 hash. Linux birth time comes from `statx` when available; macOS and Windows use their native metadata APIs. Runtime assertions currently run on Linux; native Mac and Windows setters have cross-build coverage.

Birth time is recorded. macOS and Windows attempt native setters and verify readback. Linux writes `difz.btime` and warns once per apply. Capture prefers that sidecar over the kernel birth time. The sidecar explicitly represents either absence or signed seconds plus nanoseconds; it can suppress a new inode's birth time when the original recorded none. Symlinks use parent transport for the same purpose.

When a volume cannot represent the requested timestamp, apply keeps the native value, preserves the original in `difz.mtime`, and warns once. The transport also records the native stamp observed during restore. Capture uses the original only while that stamp still matches; changing the native timestamp invalidates the stale sidecar and causes source verification to fail. The host regression uses an out-of-range timestamp on a read-only file to exercise this fallback and then checks rejection after a native timestamp change. The pure Windows mapping test checks 100 ns precision; other volume granularities require runtime qualification on those filesystems.

## Omit

`--omit-metadata` strips families before capture and hashing. The CLI accepts comma-separated lists of `xattr`, `acl`, `timestamps`, `finder`, `sparse`, and `hardlink`. The C boundary accepts the corresponding bit mask. An omitted family is absent from the patch and the identity and produces no warning. Apply reads the stored mask and uses it for both source capture and staged verification. All 64 subsets are tested against every family of source changes.

Header flag bit 0 (`0x1`) is unrelated. It is set only when the target snapshot root has metadata. The body then ends with a `u32` length and one canonical metadata record for that root. Bits 1 through 6 hold the omission mask in the family order above. Bits 7 through 31 are rejected, as are metadata payloads that contradict the mask. The source root is part of the source hash and is not stored: apply re-reads it from the source directory.

The snapshot root cannot be an entry. `validatePath` rejects an empty path. Gatekeeper looks at the directory the user opens (`Beamer.app`), so its attributes have to ride this trailer. `treeHashWithRoot` with an empty root equals `treeHash`. A non-empty root appends the domain `DIFZTREE-ROOT\x01` and the BLAKE3 of that canonical record.

## Extended attributes on disk

Snapshot and apply call `xattr_stream` with `follow_symlinks = false`. A name `fromNative` accepts is stored as logical, without a `user.` prefix. Anything else is raw, under the native name. `com.apple.ResourceFork` is skipped. So are `system.posix_acl_access` and `system.posix_acl_default`; those belong to the ACL family. Transport names are not captured again, except `difz.raw-xattrs`, which is decoded and merged back so a sidecar still hashes as the original raw attributes.

Logical names are set on apply. A failure there fails the apply. A raw name this OS rejects, or a raw set that returns permission or unsupported, is packed into `difz.raw-xattrs` with one stderr line. Values above 64 KiB fail the snapshot (`error.TooLarge`) rather than being dropped.

The filesystem root record includes xattrs, ACLs, mtime, birth time, and Finder fields. Root mode is outside this record; sparse extents and hardlink references apply only to regular files. Timestamp transport is stored while objects are writable, then final permissions are applied. Directory times follow child writes. The staged check hashes entries and the root record together.

The 2026-10-04 host tests cover a logical `comment` and a raw quarantine name on a file, and the same pair on the snapshot root, through create and apply. On macOS the root also carries `com.apple.provenance` and `com.apple.macl`. The quarantine name is `com.apple.quarantine` there and `user.com.apple.quarantine` on Linux. Writing a quarantine attribute that was not on the source is not part of this path.

`./test` requires the host filesystem metadata suite and the default CLI path as well as the Nix checks. It sets `DIFZ_REQUIRE_XATTR_TESTS=1` for the host unit run, so unsupported xattrs fail the complete entry point. In the Nix sandbox, a filesystem without xattrs reports metadata-dependent unit cases as skipped. The sandbox CLI round trips explicitly omit timestamps because Linux birth-time preservation requires attribute writes; the required host CLI round trips keep default metadata. Pure patch tests also run in the sandbox. This split keeps sandbox limitations visible while requiring the complete metadata path on the host.

## Best-effort restore

Try the native operation. On success, do not leave a sidecar. On failure, write the sidecar and warn on stderr. The staged-tree check still requires the canonical record, which a later snapshot rebuilds from the native API or from the sidecar. If the sidecar cannot be written either, apply fails. That keeps "warning" from meaning "identity silently changed."

Decision, 2026-10-08: when a symlink cannot store metadata natively, preserve the unsupported fields in a transport attribute on its parent directory. This is implemented as `difz.symlinks`, with sorted basename records containing only the preserved fields. Capture merges those fields with native metadata before applying the omission mask. Missing names, nonsymlinks, malformed records, and oversized transport fail rather than silently dropping metadata. Parent transport is excluded from the parent's canonical xattrs. Apply returns a per-call compromise mask through the C boundary; the CLI warns once per category after publication. Omitted families stay absent and produce no warning.

The 2026-10-01 archive measurement covers a ditto zip of an already-signed app, not this metadata layer. A reconstructed `.app` tree is still not a Gatekeeper pass.

## ACL filesystem ports

Linux captures both `system.posix_acl_access` and `system.posix_acl_default`. The native blob is `DIFZACL\x01`, access/default u32 lengths, and their kernel bytes. The access ACL also maps to portable read/write/execute entries, with decimal numeric IDs for named principals. Default ACLs remain in the native form. Both sets are validated before restore. Representable portable ACLs are attempted on Linux; foreign principal names stay in transport.

macOS uses no-follow extended ACL APIs and their bounded text representation. Windows records the DACL and its inheritance-protection flag, with explicit NULL-DACL representation; owner/group and privileged SACLs remain outside this scope. ACE bounds are checked before native calls. Windows static-library consumers must link `advapi32` as well as the usual system libraries. Native setters compile for both Windows architectures and macOS; current runtime assertions are on Linux. [Apple's ACL API](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/acl_to_text.3.html) and [Microsoft's security API](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo) define these native forms.

Restore verifies canonical native and portable readback separately. Unsupported or foreign forms use `difz.native-acl` and `difz.portable-acl`, each encoded as a canonical metadata record containing only its named field. Empty records preserve absence when a destination generates an ACL. Other fields in these sidecars are rejected. Symlinks use parent transport; its ACL-override flag preserves both presence and absence. ACL omission skips native capture and sidecar reads.

Transport is written while objects are writable. Native ACLs are then reapplied after final chmod, in parent-before-child order because Windows can propagate inherited ACEs. The complete staged hash checks the final ACLs and modes together. Linux integration tests independently read back kernel access and default attributes, exercise root ACLs, preserve foreign forms on a read-only file, and reject invalid sidecars.

## Finder filesystem fields

macOS captures `com.apple.FinderInfo` as exactly 32 typed bytes and BSD flags from no-follow stat, including the snapshot root. Finder information stays out of the xattr family, including when Finder metadata is omitted. Linux and Windows preserve foreign Finder fields in `difz.finder-info` and `difz.bsd-flags`. Each sidecar is a canonical metadata record containing only its named field; an empty record preserves canonical absence. Symlinks use the parent transport with a Finder-override flag, so inherited fields can also be suppressed.

The macOS setter attempts native Finder information and the `UF_NODUMP` and `UF_HIDDEN` flags. Other BSD flags remain in transport with a warning. In particular, immutable, append-only, and OS-managed flags must not prevent staging cleanup or atomic publication. Existing OS-managed flags are left intact; a sidecar preserves the requested canonical value when they differ. This is a reported fidelity compromise, not native equivalence for those flags. Linux tests cover foreign fields on a read-only file, directory, symlink, and root, plus omission. The macOS native readback case is present in the complete suite but requires a macOS host; cross-builds alone do not qualify that filesystem behavior.

## Sparse filesystem extents

Linux and macOS capture the holes reported by `SEEK_HOLE` and `SEEK_DATA`; Windows queries allocated ranges and takes their complement within the logical file length. Unsupported extent queries contribute no native hole record. Apply tries Linux hole punching, Darwin `F_PUNCHHOLE`, or Windows sparse/zero-data controls, then queries the resulting layout again. A mismatch uses `difz.sparse-holes`, a canonical metadata record containing only the hole list, with one warning. An empty list can suppress destination-generated holes. Omitting sparse metadata skips both queries and transport.

The logical payload always contains the complete bytes. Holes must remain within the file and contain only zeros. Filesystem allocation units can exceed a requested range, so a valid one-byte hole may require transport even where large aligned holes restore natively. Capture records the filesystem's reported extent view; compression and allocated block counts alone do not identify holes.

The Linux fixture grows across allocation units until the kernel independently confirms a hole, synchronizes fixture writes without sleeps, and checks native hole offsets, logical bytes, and allocated block counts after apply. The fallback test covers a one-byte hole on a read-only file. Pure tests exhaust all 256 eight-byte allocated layouts, and the injected query port checks pagination, nonprogress rejection, and every allocation failure. Mac and Windows ports have cross-build coverage; their runtime extent behavior still requires host qualification.

## Hardlink groups

Capture validates transported references against the complete snapshot, then groups native hardlinks by device and inode. Filtering rebases each group onto its first included path; equal contents never merge unrelated groups. References must name an earlier regular file with identical bytes, mode, and shared metadata, and cannot form chains.

Apply first attempts native linking. Unsupported linking, permission restrictions, cross-device errors, and link-count limits permit a copy fallback. Storage exhaustion and unrelated errors remain failures. Each copied alias stores a canonical metadata record containing only `hardlink_to` in `difz.hardlink-to`. Readback validates the group and the complete staged identity before publication. The CLI reports the copy compromise once per apply. Failure to store the transport fails apply.

Linux tests inject unsupported linking, independently confirm distinct inodes for the resulting copies, check canonical readback and omission, and exercise every allocation failure with stage cleanup. Pure tests exhaust all 32 subsets of two interleaved groups and classify the complete native linking error set.

## Validation, 2026-10-08

The complete `./test` entry point passed, including required host metadata assertions, the default CLI metadata path, sandbox unit and CLI checks, the installed C consumer, benchmark contracts, and the Windows x86_64 build. The root-metadata regression first reproduced acceptance of regular-file-only fields, then verified rejection by both writer and preflight reader with a recomputed valid patch checksum.

ReleaseFast builds passed for Linux x86_64 and aarch64, macOS aarch64, and Windows x86_64 and aarch64. Native metadata runtime assertions ran on Linux x86_64. Cross-build success does not qualify native Mac or Windows filesystem behavior; those host runs and macOS updater qualification remain separate work.
