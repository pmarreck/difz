# DIFZTREE v2 Directory Patch Contract

Status: the sole supported directory format. There is no v1 compatibility path.

## Scope

File-to-file patches use source- and target-bound `ZDIF\x04` (one zstd level 9 prefix frame). Directory-to-directory patches always use `DIFZTREE` v2 and embed that same file frame for each changed regular file. DIFZTREE v1 and `ZDIF\x03` are rejected. Inputs must have matching kinds. A file and a directory cannot be diffed, and sockets, devices, FIFOs, and other special files are rejected.

A directory patch reconstructs a new target under a staging root. It never changes the source tree. After reconstruction, difz snapshots and hashes the staging tree again. Success requires the new hash to match the target identity stored in the patch. The caller decides whether and how to replace a live application tree.

## Canonical snapshots

The snapshot excludes the root itself. Each entry has:

- a relative path;
- a kind: directory, regular file, or symbolic link;
- a portable mode;
- regular-file bytes or portable symlink-target bytes;
- canonical metadata, including an empty record when no family is present.

The snapshot root has a separate optional metadata record; it is not an entry with an empty path.

Paths use these rules:

- valid UTF-8, preserved byte-for-byte without Unicode normalization;
- `/` is the only separator;
- no empty path, NUL, leading or trailing `/`, `\`, empty component, `.` component, or `..` component;
- no drive prefix or absolute/UNC spelling;
- strictly increasing unsigned-byte order, with no duplicate path;
- every non-top-level entry has a preceding directory ancestor.

These rules reject path aliases before a patch can create anything. The same validation runs when snapshots are created, patches are decoded, and staging paths are joined.

Symlink targets must be nonempty UTF-8 relative paths using `/`. Absolute, drive-prefixed, backslash-separated, NUL-containing, and lexically root-escaping targets are rejected. `.` and contained `..` components remain valid, so bundle-internal links such as `Versions/Current` and `../Frameworks` can round-trip without allowing a staged link to escape the reconstructed root.

On Linux and macOS, the mode stores the low nine POSIX permission bits. Symlinks use canonical mode `0777`; difz does not follow or chmod them. On Windows, snapshots assign `0755` to directories, `0644` to regular files, and `0777` to symlinks. Windows reconstruction rejects a patch whose modes cannot map to those values and otherwise ignores chmod. It marks a symlink as directory-valued when its normalized target names a directory in the target snapshot; a dangling Windows directory symlink cannot be distinguished and is unsupported. Platform artifacts should therefore be patched on their target platform.

Canonical metadata can carry extended attributes, ACLs, timestamps, Finder information and flags, sparse extents, and hardlink identity. The filesystem adapter currently captures and restores xattrs and child mtime. Other native operations and transport fallbacks remain in [the metadata plan](plan_context/metadata-v2.md). Owner/group IDs and ctime are outside the declared scope. A format's ability to carry a field does not establish native filesystem fidelity.

`--omit-metadata xattr,acl,timestamps,finder,sparse,hardlink` omits the listed families before capture and hashing. The patch stores the mask so apply uses the same scope for source and staged verification. Omitted families have no payload and produce no fidelity warning. Repeated options combine disjoint lists; unknown, empty, and duplicate families are errors. This option applies only to directory patch creation.

## Filters

Snapshots may carry an ordered list of include and exclude glob rules. With no rules, every supported entry is included. If any include rule exists, the initial verdict is excluded; otherwise it is included. Each matching rule replaces the verdict, so the last matching rule wins. A leading unescaped `!` flips the rule action and is removed before compilation.

Glob behavior matches dirtree's PCRE2-backed path globs:

- `*` matches zero or more non-separator bytes;
- `**` matches across separators;
- `**/` matches zero or more complete path components;
- `?` matches one non-separator Unicode code point;
- bracket classes and their `!`/`^` negation are supported;
- `\*`, `\?`, and `\[` are literals, including when embedded in a pattern;
- matching is case-sensitive on every platform and applies to the complete canonical relative path.

Traversal does not stop at an excluded directory because a later rule may re-include a descendant. Any included descendant forces its directory ancestors into the snapshot as structural entries. The patch stores ordered rule actions and patterns as supplied, including a leading `!`, so apply uses the same source scope. Changes outside that scope do not affect the source or target identity.

## Tree identity

Both source and target identities are 32-byte BLAKE3 hashes over this canonical stream:

```text
"DIFZTREE-ID\x02"
entry_count                 u32 little-endian
for each entry:
    kind                    u8
    mode                    u16 little-endian
    path_length             u32 little-endian
    path                    path_length bytes
    content_length          u64 little-endian
    content                 file bytes, symlink target, or empty for a directory
    metadata_blake3         BLAKE3("DIFZMETA\x01" + canonical metadata bytes)
if root metadata is nonempty:
    "DIFZTREE-ROOT\x01"
    root_metadata_blake3    BLAKE3("DIFZMETA\x01" + canonical root metadata bytes)
```

The source identity is checked before reconstruction. This catches a wrong same-sized source tree. The independently re-snapshotted staging tree must match the target identity before success.

## Patch encoding

All integers are little-endian. Header:

```text
magic                       8 bytes: "DIFZTREE"
format_version              u16: 2
minimum_reader_version      u16: 2
flags                       u32: bit 0 target-root metadata; bits 1..6 omission; others reserved
rule_count                  u32
entry_count                 u32
source_tree_blake3          32 bytes
target_tree_blake3          32 bytes
patch_blake3                32 bytes
```

`patch_blake3` is BLAKE3 over domain `DIFZTREE-PATCH\x02`, the preceding 88 header bytes, and the complete body. It binds every encoded byte, including file-delta metadata that does not affect reconstruction. The decoder rejects every format version except 2 before allocation.

Each ordered filter rule follows:

```text
action                      u8: 1 include, 2 exclude
flags                       u8: 0
reserved                    u16: 0
pattern_length              u32
pattern                     pattern_length UTF-8 bytes
```

Target entries then appear in strict canonical path order:

```text
operation                   u8
flags                       u8: 0
mode                        u16
path_length                 u32
payload_length              u64
path                        path_length bytes
payload                     payload_length bytes
metadata_length             u32
metadata                    metadata_length canonical bytes
```

When header bit 0 is set, the entries are followed by `u32 root_metadata_length` and a nonempty canonical target-root metadata record. The source root is hashed but not stored; apply obtains it from the source snapshot.

Header bits 1 through 6 omit xattrs, ACLs, timestamps, Finder fields, sparse extents, and hardlinks, respectively. Bits 7 through 31 are reserved. A payload containing an omitted family is invalid, including in the root record.

Canonical metadata serializes xattrs, portable ACL entries, an optional origin-tagged native ACL, optional timestamps, Finder flags and information, sparse holes, and an optional hardlink path, in that order. Collection counts and byte lengths are u32; sparse offsets and lengths are u64; timestamps use signed i64 seconds and u32 nanoseconds. An empty canonical record is 20 zero bytes. See `src/metadata.zig` for the field layout and [metadata scope](plan_context/metadata-v2.md) for capture and restore decisions.

Operations are:

- `1 directory`, with no payload;
- `2 symlink`, with the target bytes as payload;
- `3 file-copy`, with no payload and bytes copied from the same source path;
- `4 file-raw`, with complete target bytes as payload;
- `5 file-delta`, with a current file-level difz patch as payload and the same-path source file as its base.

Unchanged same-path files use `file-copy`; mode changes are carried by the entry mode. Changed same-path regular files use `file-delta`. Additions and source-kind changes use `file-raw`. A source entry absent from the target manifest is deleted by omission because staging starts empty. Identical-content rename detection is deferred.

The decoder rejects trailing bytes, unsupported versions or flags, nonzero reserved fields, invalid UTF-8, invalid or unsorted paths, duplicates, impossible operation/payload combinations, missing source files for copy/delta, and every file-core decoding error.

Default parser limits are 1,000,000 entries, 4,096 rules, 4,096 bytes per path or pattern, 65,536 bytes per symlink target, 8 GiB per payload, 16 GiB per patch, and 64 GiB expanded output. Callers may lower them. Every count and length is checked before conversion to `usize`, addition, allocation, or write.

## Filesystem commit behavior

Create writes a temporary patch beside the requested output and renames it only after encoding succeeds. Apply requires a nonexistent output path, creates a uniquely named sibling staging directory, validates the complete patch and source identity, writes entries without following symlinks, and re-snapshots the stage. Any failure closes handles and removes only that owned staging path. A verified stage is renamed to the requested output path. The source remains unchanged, and replacing a live tree remains a separate caller action.

The logical bundle contents, relative paths, symlink targets, portable modes, and currently supported metadata can round-trip exactly. Remaining native metadata work and updater qualification must pass before claiming filesystem equivalence for a notarized macOS `.app`.
