# DIFZTREE v1 Directory Patch Contract

Status: implementation contract for the first directory-capable difz release.

## Scope

Existing file-to-file patches keep the current `ZDIF\x01` format. Directory-to-directory patches use `DIFZTREE` v1. Inputs must have matching kinds. A file and a directory cannot be diffed, and sockets, devices, FIFOs, and other special files are rejected.

A directory patch reconstructs a new target under a staging root. It never changes the source tree. After reconstruction, difz snapshots and hashes the staging tree again. Success requires the new hash to match the target identity stored in the patch. The caller decides whether and how to replace a live application tree.

## Canonical snapshots

The snapshot excludes the root itself. Each entry has:

- a relative path;
- a kind: directory, regular file, or symbolic link;
- a portable mode;
- regular-file bytes or the uninterpreted symlink-target bytes.

Paths use these rules:

- valid UTF-8, preserved byte-for-byte without Unicode normalization;
- `/` is the only separator;
- no empty path, NUL, leading or trailing `/`, `\`, empty component, `.` component, or `..` component;
- no drive prefix or absolute/UNC spelling;
- strictly increasing unsigned-byte order, with no duplicate path;
- every non-top-level entry has a preceding directory ancestor.

These rules reject path aliases before a patch can create anything. The same validation runs when snapshots are created, patches are decoded, and staging paths are joined.

On Linux and macOS, v1 stores the low nine POSIX permission bits. Symlinks use canonical mode `0777`; difz does not follow or chmod them. On Windows, snapshots assign `0755` to directories, `0644` to regular files, and `0777` to symlinks. Windows reconstruction rejects a patch whose modes cannot map to those values and otherwise ignores chmod. Platform artifacts should therefore be patched on their target platform.

Owner, group, timestamps, ACLs, extended attributes, Finder flags, sparse extents, and hardlink identity are outside v1. Hardlinks snapshot as independent regular files.

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

Traversal does not stop at an excluded directory because a later rule may re-include a descendant. Any included descendant forces its directory ancestors into the snapshot as structural entries. The patch stores the normalized ordered rules so apply uses the same source scope. Changes outside that scope do not affect the source or target identity.

## Tree identity

Both source and target identities are 32-byte BLAKE3 hashes over this canonical stream:

```text
"DIFZTREE-ID\x01"
entry_count                 u32 little-endian
for each entry:
    kind                    u8
    mode                    u16 little-endian
    path_length             u32 little-endian
    path                    path_length bytes
    content_length          u64 little-endian
    content                 file bytes, symlink target, or empty for a directory
```

The source identity is checked before reconstruction. This catches a wrong same-sized source tree. The independently re-snapshotted staging tree must match the target identity before success.

## Patch encoding

All integers are little-endian. Header:

```text
magic                       8 bytes: "DIFZTREE"
format_version              u16: 1
minimum_reader_version      u16: 1
flags                       u32: 0
rule_count                  u32
entry_count                 u32
source_tree_blake3          32 bytes
target_tree_blake3          32 bytes
```

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
```

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

The logical bundle contents, relative paths, symlink targets, and portable modes can round-trip exactly. V1 cannot claim byte-for-byte filesystem equivalence for a notarized macOS `.app` when correctness depends on metadata outside that set.
