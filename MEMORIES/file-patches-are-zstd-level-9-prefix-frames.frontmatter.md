---
description: "difz file patches are one zstd level 9 prefix frame, and zstdz is the only compressor dependency."
datetime: 2026-10-08T00:31:35-04:00 # EDT
tags: [memory, difz, zstd, zstdz, patch-from, zdif]
---

A regular-file patch is ZDIF v4: magic `ZDIF` plus version byte 0x04, the source BLAKE3, the target BLAKE3, two little-endian lengths, then one zstd frame. The header is 85 bytes. Level 9 is fixed and single-threaded. The window log is floor(log2(max(source, target)))+1, clamped to 10 through 31. Either input longer than 2 GiB is rejected. Decode allows a 2 GiB window. The source BLAKE3 is checked before the reconstruction allocation.

Directory patches stay DIFZTREE v1. Each changed file body is one of those frames. `ZDIF\x03` is rejected.

The linked compressor is the zstdz fork. lz4, bzip2, LZMA2, blar, and BLIP are not dependencies. PCRE2, progrez, and xattr_stream stay.

A Nix flake build copies git-tracked files. A new source file stays invisible to `./test` until it is staged.

The content-defined chunking engine remains at the pre-change commit on `yolo`. One 2026-10-08 ReleaseFast run of the same NixOS minimal ISO pair wrote 557,171,921 bytes in 11.77 s wall and applied in 3.74 s. The reconstruction SHA-256 matched the newer ISO.
