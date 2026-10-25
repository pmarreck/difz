# Rust codec qualification and source ownership

Structured-zstd 0.2.5 now passes local, Nix-built raw-prefix interoperability
and bounded-output checks. It supplies a caller-sized output-buffer API with
an explicit raw dictionary. That is a different API from its allocation-free
workspace decoder, which has no prefix installation method.

The production implementation remains zstdz. These are QA adapters and
measurements to inform the Rust migration, not a product switch.

## Correctness and bounds

The shared cross-apply checks cover empty input/output, all byte values,
embedded NUL and invalid UTF-8 bytes, scattered edits, and moved data. Native
difz independently produces the ZDIF header and applies each candidate frame,
checking the source/target BLAKE3 identities. Every reconstructed result is
also compared directly with the expected target bytes. Wrong-source and
corrupt-target-identity controls must fail without publishing an output.

A 64 KiB target from the beginning of a 2 MiB high-entropy source exercises
distant raw-prefix reach. The source begins with trained-dictionary magic,
but the adapter explicitly constructs a raw-content dictionary with ID zero.
The prefix frame is smaller than one eighth of the target, ordinary
compression cannot pass that size gate, and decoding without the prefix fails.

`FrameDecoder::decode_all_with_dict_handle` accepts a caller-owned output
slice. Tests supply capacities zero, one, one byte short, exact fit, and
16 bytes extra. Insufficient capacity fails; successful results have the
expected length and bytes. Guard regions before and after every supplied
slice remain unchanged, including on errors.

Checksum handling must be configured. Structured-zstd defaults to `EmitOnly`,
which computes the checksum without rejecting a mismatch. The adapter selects
`ContentChecksum::Verify`. A frame produced independently by Rusty_zstd is
accepted with its valid checksum, rejected after a checksum-bit mutation,
and accepted with unchanged target bytes by the unconfigured default decoder.
This control establishes that the explicit setting changes behavior.

Encoder and decoder limits differ. The parameter builder accepts encoder
window log 30 (1 GiB) and rejects 31. The caller-buffer decoder can read a
small valid prefix frame advertising a 2 GiB window without reserving that
window: a tested retained-workspace count stays below 16 MiB. Its configured
1 MiB streaming-window ceiling does not apply to this caller-buffer path,
which bounds history through the caller's output storage. The same decoder's
streaming reset rejects that frame under the 1 MiB ceiling. This matches the
documented distinction between direct and retained-window decoding. It does
not establish effective history reach or resource use for 2 GiB input.

The package is pinned to 0.2.5, registry checksum
`096c39fadb89b2a367a97308d59bcfabb268f9263e9d84a049b5ce14f1457ba6`.
That matches the independently prefetched published crate. Only `std`, `hash`,
`ldm`, and the supplied CPU-kernel features are enabled; dictionary training
and legacy-frame support are unnecessary here. Its sole transitive dependency
in this resolution is checksummed `twox-hash` 2.1.5. The QA package requires
Rust 1.92; the pinned build uses Rust 1.94.1.

The nine-function codec suite completes in about one second on the measured
Linux host. A separate required probe check cross-applies each probe encoder
through every probe decoder and the pinned zstdz CLI, including empty and
binary inputs, path spaces, invalid codec names, and owned/borrowed frame
identity. Both checks run under `checks.<system>.rust-codec`, reached by the
complete `./test`. This is finite correctness evidence, not a security audit,
complete hostile-input qualification, or native qualification of other OSes.

## A common measurement boundary

`difz-codec-probe`, installed by `packages.<system>.rust-codec-tests`, measures
fresh codec contexts after input files have been read and before output files
are written. Its Rust `Instant` interval includes codec setup, prefix handling,
output allocation, compression/decompression, and context teardown. Owned
Structured calls also consume and dispose of the transferred source buffer
within that call; borrowed calls leave the caller's original source alive.

The C anchor uses the pinned zstdz C source `abaedb3e`, built by the native
GCC 15.2.0 toolchain with upstream optimized defaults. It uses the same
level-9 parameter selection, explicit window, LDM decision, raw prefix and
zero-worker setting as difz's file core. C and Rust run inside the same Rust
probe executable, avoiding different CLI implementations as a kernel-timing
confound. C declarations are generated from that exact header during the Nix
build. Its static library uses the Rust host's native ABI. The benchmark-only
FFI module checks C statuses and buffer lengths and frees each context; the
shared Rust codec adapters forbid unsafe code.

Rusty_zstd 0.4.1 and Structured-zstd 0.2.5 use their level-9 parameters with
the same requested window and LDM enabled. Their internal algorithms and
defaults are not claimed to be equivalent. All encoders disable frame
checksums; candidate decoders retain checksum verification for frames that
do contain one.

Each encode result is reconstructed by the C decoder and byte compared
outside timing. Decode cases all consume the same C-produced frame for a
given size, so different candidate encodings do not confound decoder timing.
The owned-matrix run also compares every timed encoded frame with its warmup
reference. Source and target data are the earlier 50% seeded-random/50% zero
block layout, with new randomness replacing 6.25% of the file. Sizes are
4, 16 and 64 MiB; source, target and C-frame identities are retained in
[the fixture CSV](../benchmarks/codec-prefix-20261025-fixtures.csv).

## Results with source ownership accounted for

These are arithmetic means of three fresh processes per case, with affinity
restricted to one logical CPU. `C` borrows its prefix. `Rusty` uses its
borrowed-prefix API. `Structured borrowed` copies the caller's slice into
an owned raw dictionary. `Structured owned` transfers an existing `Vec<u8>`
instead. The latter two use the same codec and emit identical bytes on all
measured cases.

| Input MiB | Adapter | Encode ms | Decode ms | Encode peak RSS MiB | Decode peak RSS MiB | Frame bytes |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 4 | C | 38.2 | 2.1 | 20 | 9 | 263,273 |
| 4 | Rusty | 108.7 | 2.1 | 39 | 9 | 264,128 |
| 4 | Structured borrowed | 40.6 | 4.8 | 36 | 13 | 262,833 |
| 4 | Structured owned | 40.2 | 2.3 | 32 | 9 | 262,833 |
| 16 | C | 128.5 | 8.3 | 48 | 34 | 1,053,229 |
| 16 | Rusty | 505.2 | 8.4 | 92 | 34 | 1,057,189 |
| 16 | Structured borrowed | 217.1 | 19.2 | 110 | 50 | 1,051,340 |
| 16 | Structured owned | 147.9 | 12.5 | 94 | 34 | 1,051,340 |
| 64 | C | 255.9 | 32.3 | 159 | 133 | 4,213,663 |
| 64 | Rusty | 1,840.7 | 33.4 | 290 | 133 | 4,227,377 |
| 64 | Structured borrowed | 430.3 | 80.6 | 407 | 197 | 4,205,760 |
| 64 | Structured owned | 351.0 | 42.4 | 343 | 133 | 4,205,760 |

On this 64 MiB workload, transferring source ownership removes the
Structured adapter's additional 64 MiB peak RSS during decoding. Its measured
codec-call decode time is about 32% above C, compared with about 150% for the
borrowed wrapper. Its encoding is about 37% slower than C, with roughly
2.2 times C's process peak RSS. Rusty's encoding takes about 7.2 times C's
time. Structured frames are about 0.19% smaller than C's; Rusty frames are
about 0.33% larger. These findings describe this edit distribution, not all
binaries or all compression levels.

Whole-probe process time is a separate metric. At 64 MiB, decode averaged
137.2 ms for C, 136.3 ms for Rusty, 192.6 ms for Structured borrowed, and
140.8 ms for Structured owned. This includes warm RAM-backed file reads and
writes, process setup, and buffer lifetime beyond the kernel interval.
The small C/Rusty/owned whole-process gaps are not evidence of a general
application-speed difference; this was a three-sample matrix rather than
the paired identical-input experiment used for
[worker-produced patch application](zstd-worker-apply.md). It also excludes
difz's BLAKE3 checks and tree/metadata work.

The separate 12-CPU allowance is retained in the CSV. No adapter requests
compression workers; that allowance does not make these algorithms parallel.
At 64 MiB, its C/Structured-owned encode times were 260.0/353.2 ms and decode
times were 31.7/46.5 ms. Both codec-call and whole-process measurements must
remain qualified by their own CPU cohort.

## Provenance and limits

The ownership-aware matrix has 48 cases and 144 final samples. Two noisy
cases used the shared profiler's single permitted retry: one-core 16 MiB
Structured-owned decode and 12-core 16 MiB C encode. Their six first-attempt
samples remain marked `diagnostic` in
[the 150-row sample CSV](../benchmarks/codec-prefix-ownership-20261025-samples.csv).
Every final case was `UNBASELINED`, within the configured 30% coefficient
of variation, with correct outputs and an unchanged measured-source
fingerprint. No baseline approval or historical regression-gate pass is
claimed.

An earlier 36-case borrowed-adapter matrix is preserved in
[its 108-row CSV](../benchmarks/codec-prefix-borrowed-20261024-samples.csv).
It motivated the ownership follow-up rather than being discarded. The
adapter refactor and probe binary changed between runs, so differences across
those runs do not isolate ownership cost; the main table uses only the second
matrix. Within that matrix, source transfer, allocation order and lifetime
can all contribute to timing. Peak RSS is process-wide, includes preloaded
input buffers, and is not an allocator count or leak measurement.

The earlier probe SHA-256 was
`a0b73dd342aa7b03b63c8b739d7208d7104049ebe1f68315419c4109c4d4c95e`;
the ownership-aware probe was
`f053e955e81bd3734e4aa5e61385bff0e928f169379d24d1cbb2ac7d8e2d45e3`.
Both were optimized Nix-built artifacts on Linux x86_64, using the same
AMD Ryzen Threadripper 3990X as the worker measurements. Case order was
shuffled with seed 44, and CPU affinity was enforced with `taskset`.
Each sample starts a fresh process/context and uses warm files. Hyperfine
1.20.0 measures full-process wall time; GNU time 1.10 supplies process CPU
at 0.01-second resolution and process peak RSS. Input verification is outside
the timed intervals.

Each matrix ran in one `build-budget` job under the qualified Bubblewrap
read-only-host boundary, with private writable fixtures and history. A
checkout-write canary was rejected. Setup took 9 seconds in each run;
isolated totals were 61 seconds for the first matrix and 78 seconds for the
ownership matrix, including verification and profiler work. Artifact builds
were prepared separately. The extended matrix is not a required quick gate;
its adapter correctness and independent cross-apply controls are required by
the ordinary test entry point.

Remaining adoption work includes malformed-input/fuzz coverage, complete
resource contracts, native ARM/macOS/Windows qualification, actual release
pairs and any decision to narrow the requested encoder window. The default
Structured decoder checksum mode and raw-prefix ownership cost are integration
requirements, not reasons to silently change difz's product contract.
