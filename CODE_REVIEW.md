# difz upgrade-readiness review

Status note, 2026-10-08: the findings below describe the content-defined chunking engine and its BLIP, lz4, and z7z link surface. The file engine on this branch is a ZDIF v4 zstd level 9 prefix frame. The installed archive links pcre2 and zstd. The CDC, compressor-probe, and chunk-size findings do not apply to that engine. The review text is kept as the record of what was found.

Reviewed commit: `433ae3e5a600` (`yolo`, 2026-09-04).
Reviewers: Codex/Astra deep-code-review agents (blocked mid-report by OpenAI's cybersecurity filter) plus independent recovery and re-checks in this Grok session.

Scope was a defensive review of this repository. No exploit development. Canonical `./test` was reported green at review time; these findings sit outside that coverage.

Astra wrote working notes and reproductions under `/tmp/difz-review-20260904-gqsy92/` and `/tmp/dispatch-log/`. Those files are session artifacts, not source of truth. Claims below are labeled **runtime-confirmed this session**, **runtime-confirmed by Astra (not re-run here)**, or **source-only**.

## Confirmed defects

### CRITICAL: buffered output failures report success

`src/difz.c:218` (`write_output`). `fwrite` is checked; `fclose` and `fflush` are not. Stdout/stderr are never flushed. A write that lands only in the stdio buffer, then fails at flush, still exits 0.

Runtime-confirmed this session against `zig-out/bin/difz` (Debug, 2026-08-28):

| invocation | exit |
|---|---|
| `difz README.md README.md -o /tmp/control.patch` | 0 |
| `difz README.md README.md -o /dev/full` | 0 |
| `difz README.md README.md > /dev/full` | 0 |

A live updater that trusts a zero exit will treat a missing patch or reconstructed binary as published. Named `fopen(..., "wb")` also truncates an existing destination before a later failure.

Repair: check `fflush`/`ferror` on streams and `fclose` on named files; add CLI regressions against `/dev/full` (skip when that device is absent). Atomic publication of reconstructed files is a follow-up, not this first fix.

### WARNING: directory `-o @stderr` creates a literal file

Help documents `@stderr` as an output stream. File diffs honor it via `write_output`. Directory diffs call `is_stdout_path` (`src/difz.c:258`), which treats every other token as a filesystem path and sends it to `difz_write_new_file_atomic`.

Runtime-confirmed this session: two empty directories, `-o @stderr`, exit 0, 0 bytes on stderr, regular file `./@stderr` created (120 bytes). Directory patch already rejects `@stderr` at `src/difz.c:489`; directory diff does not.

Repair: one stream-path helper used by both file and directory writers.

### WARNING: duplicate chunks expand into a Cartesian match list

`src/chunk_match.zig:74-86`. For a hash with `A_h` source hits and `B_h` target hits, every pair is materialized. Candidate count is `sum(A_h * B_h)`.

Astra runtime-confirmed (not re-run here) with an independent ReleaseFast probe, zero seed, 4096-byte target chunks, zero-filled inputs:

| size each | candidates |
|---|---:|
| 4 MiB | 65,536 |
| 8 MiB | 262,144 |
| 16 MiB | 1,048,576 |

Doubling input quadrupled candidates. Derived 1 GiB case: 2^32 candidates, 96 GiB of 24-byte `Match` payloads before sorting.

Repair: index source hashes and pick one verified source occurrence per target chunk. Add deterministic candidate-count tests on repeated, padded, moved, and unique corpora. Do not gate this with wall-clock assertions.

### WARNING: encoder keeps one page-backed allocation per operation

`src/lib.zig:33` uses `std.heap.page_allocator`. `src/encoding.zig:336-375` allocates a DATA container per COPY/INSERT and holds them all until ARRAY construction and compression finish. On this host, Zig's PageAllocator rounds each nonempty mapping to 4096 bytes.

The committed Linux x86_64 Validate row is 708,379 operations. Instruction-container pages alone are `708379 * 4096 = 2,901,520,384` bytes (~2.70 GiB). Measured create RSS was 3,497,792 KiB (~3.34 GiB). Astra also measured 7,600-op / 15,344-op interleaved probes at 32,404 / 66,140 KiB peaks with compression off.

Repair: serialize into contiguous ARRAY storage, or use a reclaiming arena for instruction temporaries while the returned buffer stays on the caller's allocator (`difz_free` contract). Add an allocation-count or peak-page budget test with many tiny operations.

### WARNING: installed `libdifz.a` is not a complete C consumer contract

`build.zig:113-121` installs the header and static archive only. The in-repo C CLI links extra archives from the Zig graph (PCRE2, BLIP/blar, LZ4, ZSTD, zlib). An external caller using only the installed files cannot link.

Astra runtime-confirmed (not re-run here) against `/nix/store/mvgcrazxdjlc8cln1vrwxms6hvj3z8z8-difz-0.1.0`: undefined `LZ4F_*`, `ZSTD_*`, `pcre2_*`, `blip_error_string`. A paired control with those archives plus extracted nested zlib did link and reconstruct a 7-byte target.

Repair: ship a flattened archive or install dependency archives with explicit link metadata. Add a consumer build that uses only installed outputs.

### WARNING: huge `target_chunk_size` aborts Debug hosts

`src/lib.zig:47-56` forwards an unrestricted `size_t` into `src/cdc.zig:23` (`target_size * 4`) and `src/cdc.zig:69` (`1 << (bits - clz)`).

Astra runtime-confirmed (not re-run here) with an external C caller against the installed Debug package:

| `target_chunk_size` | Debug | ReleaseFast (tiny fixture) |
|---|---|---|
| 1024 | exit 0, round-trip ok | exit 0 |
| 0 | exit 0, round-trip ok | exit 0 |
| `2^62` | exit 134, panic at `cdc.zig:23` | accepted, reconstructed |
| `SIZE_MAX` | exit 134, panic at `cdc.zig:69` | accepted, reconstructed |

The documented `-1` error return does not catch Zig panics. Zero is accepted and undocumented.

Repair: reject out-of-range scalars before CDC with checked multiply / power-of-two. Cover boundaries through a real C caller in Debug and ReleaseFast.

### WARNING: Windows-only helper calls removed Zig 0.16 API

`src/directory_fs.zig:191` uses `std.mem.trimLeft`. Pinned Zig 0.16 exports `trimStart`. Linux compilation never compiles this branch. Astra's `x86_64-windows-gnu` build failed earlier on missing target zlib, so this is source-only, not a completed cross-build failure.

Repair: `trimStart`, plus a Windows zlib/sysroot in CI so the five CLI targets actually compile.

## Advisories

- `--no-ansi` / `--no-color` / `--simple` are accepted no-ops (`src/difz.c:418-425`). Astra captured `ESC[2K` under `--simple` on a PTY.
- Installed archive also exports `blar_*` and `z7z_*` symbols (91 + 21 on the ReleaseFast archive Astra inspected). Collision risk is artifact-proven; a downstream clash was not reproduced.
- `difz.h` omits `extern "C"`, does not say `difz_free` covers directory output, and collapses file-patch errors to `-1`.
- `compressOutput` (`src/encoding.zig:275-291`) returns `error.OutOfMemory` without freeing `top_array`. Source-only leak on that error path.
- Directory snapshotting reads files into a retained arena before filters (`directory_fs.zig`); apply retains source, reconstruction, and staged snapshots together. Source-only resource observation.

## Unverified / incomplete

- COPY range check `op.offset + op.length > a.len` in `src/patch.zig:72` (and the same pattern for output at 76 and 85) can overflow. Debug would panic; ReleaseFast wrapping could pass the check and then copy out of range. Astra did not finish a runtime proof. A persistent unit test belongs in this follow-up.
- Memory-safety, coverage, error-handling, and futile-test agents were interrupted by the same filter. Their progress notes are incomplete.
- No Windows runtime. Stdin/stdout `_setmode(..., _O_BINARY)` was not executed.
- Canonical suite was not re-run in this recovery session before remediation tests.

## Remediation status (2026-09-04)

1. Done: `write_output` checks `fclose`/`fflush`; directory diffs use `is_stream_path`. CLI tests cover `/dev/full` and `-o @stderr`.
2. Done: `rangeExceeds` uses `std.math.add`. The overflow unit test that aborted at `patch.zig:72` now returns `error.OutOfBounds`.
3. Done: `ChunkParams.fromTarget` rejects 0 and overflowing sizes; FFI maps 0 to 4096 and returns `-1` for `SIZE_MAX`.
4. Done: ZDIF v3 stores Gear min/target/max/mask. Random-data average stays within 2× of target; default remains 4096.
5. Done: matching picks one source offset per target chunk (contiguous preference). Zero-filled 256 KiB no longer yields a Cartesian list.
6. Done: `encode` uses an arena for instruction temporaries and dupes the final buffer. LZ4 encode is leak-clean under allocation injection.
7. Done: `scripts/flatten-static-lib` merges pcre2/blip/lz4/zstd objects into installed `libdifz.a`. `tests/ffi/test_installed_lib.bash` links with `zig cc`.
8. Done: `difz.h` has `extern "C"` and `difz_free` documents directory output. Windows path helper uses `trimStart`. `--simple`/`--no-ansi`/`--no-color` suppress the progress bar and ANSI debug banner.
9. Done: `x86_64-windows-gnu` cross-build uses mingw zlib; `difz.exe` is produced. `_setmode(_O_BINARY)` is called on Windows stdio. Computation-only blar/z7z modules keep `blar_*`/`z7z_*` out of `libdifz.a`.

Each item needs a failing test before the code change. Performance items use deterministic counters, not wall-clock gates.

## Skill notes (do not edit the shared skill here)

- Test the installed package from an external consumer. Dogfooding the in-repo CLI does not prove the install contract.
- Require a resource model: input bytes, distinct vs repeated chunks, candidate count, operation count, and page overhead are different axes.
- Label source-proven vs runtime-proven, and Debug vs ReleaseFast, on every panic/crash claim.
- Put complexity controls in the unit suite; keep timing history in `./bm`.
- A content filter that blocks a reviewer's final answer is not evidence of a malicious request. Durable on-disk notes survived here; the chat UI did not.
