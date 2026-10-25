# Actual parallel Zstandard application

The earlier application measurements used a serial decoder for both encoder
outputs. They did not test four- or eight-worker decoding. This experiment
implements and measures that separate scenario for ordinary compression and
full-old-binary prefix diffs. Production difz is unchanged.

## Layout and measurement boundary

The QA probe uses zstdz source `abaedb3e`, native GCC 15.2.0, and Rust 1.94.1.
The anchor follows difz's level-9 parameter/window/LDM selection. Ordinary
compression supplies an empty source; diff compression supplies the complete
old binary as a raw prefix. This is the same fork source, rather than the
shipping Zig-compiled artifact.

The parallel layout contains independent 4 MiB standard Zstandard frames.
Every prefix frame receives the complete immutable old binary. Frames cannot
refer to new target bytes from earlier frames. Eight Rust compression workers
each call the zero-worker zstdz encoder. Correctness checks establish identical
frame bytes with one, four, or eight encoder workers.

Decoding scans frame boundaries and content sizes, allocates one target buffer,
and divides contiguous frame groups among workers. Each worker owns a decoder
context, writes directly into disjoint output slices, and reattaches the old
binary for every frame. There is no final output-buffer merge. At 32 MiB,
eight frames give four workers exactly two frames each.

Upstream [PZstandard](https://github.com/facebook/zstd/blob/dev/contrib/pzstd/README.md)
also uses independent frames for parallel decompression, but lacks dictionary
mode. The [seekable-format documentation](https://github.com/facebook/zstd/blob/dev/contrib/seekable_format/README.md)
describes the compression-ratio cost of smaller independent frames. This probe
adds the full-source-prefix case; ordinary `zstd -T` output is a different layout.

The codec interval includes frame scanning, target allocation, context creation,
thread creation, decoding, joins, and context/thread cleanup. Its process CPU
clock counts all threads. Reads occur before this interval and the final write
afterward. Separate process measurements include startup and those warm
RAM-backed reads/writes. Neither interval includes difz's BLAKE3 identities,
atomic publication, directory metadata, or a durable `fsync`.

## Mixed-data results

The source is half seeded-random bytes and half zeros in 4 KiB blocks.
Replacing the random half of every eighth block changes 6.25% of file bytes.
Seeds are 42 and 43; smaller files are prefixes of the 128 MiB pair.

Tables show arithmetic means of five fresh processes per case, in milliseconds.
All table rows allow the same eight physical CPU cores, with one, four, or eight
decoder workers. One-core and four-core controls remain in the sample CSV.

| Input MiB | Codec mode | Monolithic, 1 worker | Chunked, 1 worker | Chunked, 4 workers | Chunked, 8 workers |
| ---: | --- | ---: | ---: | ---: | ---: |
| 32 | Ordinary | 19.83 | 20.19 | 7.08 | 4.78 |
| 32 | Prefix | 17.14 | 18.57 | 6.62 | 4.81 |
| 64 | Ordinary | 40.46 | 42.17 | 13.19 | 9.25 |
| 64 | Prefix | 33.56 | 33.98 | 11.45 | 7.95 |
| 128 | Ordinary | 82.97 | 82.94 | 25.70 | 17.11 |
| 128 | Prefix | 67.68 | 69.97 | 23.05 | 16.18 |

Framing alone did not produce the large gains. At 128 MiB, four/eight workers
give 2.94x/4.18x the monolithic prefix codec speed and 3.23x/4.85x the ordinary
codec speed.

The corresponding complete read/decode/write process measurements are:

| Input MiB | Process mode | Monolithic, 1 worker | Chunked, 1 worker | Chunked, 4 workers | Chunked, 8 workers |
| ---: | --- | ---: | ---: | ---: | ---: |
| 32 | Ordinary | 56.68 | 58.84 | 45.09 | 43.59 |
| 32 | Prefix | 70.15 | 75.28 | 60.87 | 59.39 |
| 64 | Ordinary | 112.45 | 115.07 | 85.94 | 82.44 |
| 64 | Prefix | 132.61 | 136.24 | 112.70 | 112.00 |
| 128 | Ordinary | 226.57 | 227.40 | 170.04 | 161.34 |
| 128 | Prefix | 265.70 | 265.95 | 218.96 | 220.38 |

At 128 MiB, ordinary process time drops by 25%/29% with four/eight workers.
Prefix process time drops by about 17–18%. The four/eight-worker prefix ranges
overlap (215–226 and 210–230 ms), so these samples do not resolve an incremental
whole-process benefit from eight workers there. File handling and startup
limit the percentage gain; they are outside the separately measured codec
interval. Additional common serial updater work also lowers percentage gains.

There is no size penalty on this corpus. At 128 MiB, ordinary frames occupy
67,253,824 bytes monolithically and 67,251,958 bytes chunked. Prefix frames
occupy 8,428,230 and 8,427,209 bytes. These small savings are data/parameter
effects, not a promise that framing improves ratio.

## Exposing the compression cost

The second corpus replaces every other 4 MiB source chunk with the same new
4 MiB block, itself half random bytes and half zeros. It changes 25% of file
bytes while introducing only 2 MiB of distinct random content. Monolithic
encoding can reuse that new block after its first occurrence. Independent
frames share the old binary, which lacks the block, and cannot reuse another
frame's reconstructed target.

| Input MiB | Mode | Monolithic bytes | Chunked bytes | Growth |
| ---: | --- | ---: | ---: | ---: |
| 32 | Ordinary | 10,509,667 | 16,813,094 | 60.0% |
| 32 | Prefix | 2,104,831 | 8,408,576 | 299.5% |
| 64 | Ordinary | 18,918,178 | 33,626,195 | 77.7% |
| 64 | Prefix | 2,108,427 | 16,817,280 | 697.6% |
| 128 | Ordinary | 35,735,306 | 67,252,396 | 88.2% |
| 128 | Prefix | 2,115,614 | 33,634,896 | 1,489.8% |

Actual parallel decoding still wins on warm RAM-backed files:

| 128 MiB mode | Monolithic codec | 4-worker codec | 8-worker codec | Monolithic process | 4-worker process | 8-worker process |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Ordinary | 72.06 | 25.79 | 15.97 | 191.64 | 168.25 | 157.03 |
| Prefix | 70.56 | 24.69 | 16.87 | 273.77 | 251.63 | 231.74 |

For sequential download then application, an approximate model is
`total = compressed_bytes / transfer_bytes_per_second + apply_seconds`.
On this 128 MiB prefix case, eight workers save 42.03 ms of process time but
add 31,519,282 patch bytes. Break-even effective transfer speed is about
750 MB/s (6 Gbit/s). Four workers save 22.14 ms, giving a threshold near
1.42 GB/s. Ordinary compression's eight-worker threshold is about 911 MB/s.
These are calculations from warm-file observations, not network or SSD
measurements. Overlapping transfer/application changes the model.

If the patch is already local, download cost is absent. Physical storage,
page-cache state, mapping/copying choices, and the complete updater need their
own qualification. These deliberately contrasting corpora establish that
parallel gains are possible and compression costs depend on content. They do
not select a universal chunk size or production default.

## CPU, memory, and independent verification

For mixed 128 MiB prefix decoding, process CPU rises from 67.20 ms to
83.49/102.88 ms with four/eight workers while wall time falls to 23.05/16.18 ms.
The parallel intervals average about 3.6/6.4 CPUs, directly establishing
concurrent execution. Extra CPU includes allocation, context/thread lifecycle,
and cache/memory effects; their individual shares were not profiled. Mixed
prefix peak process RSS stays near 264 MiB. The repeated-new prefix case's
larger compressed input raises peak RSS from about 258 to 288 MiB. RSS includes
loaded inputs and the result; it is not an allocation count or leak measurement.

An independent Lua standard-frame reader splits each encoded reference. The
pinned native zstdz CLI reconstructs each frame with the full old binary
supplied separately. Recombined bytes must equal the original target. Every
timed sample creates a new output file and is byte compared outside timing.
Required verifier regressions reject absent, stale, same-sized corrupt, and
falsely reported output. Probe controls cover empty/binary streams, worker
counts, frame-byte determinism, missing prefixes, and truncated frames. These
correctness checks are reached by `./test`.

## Provenance and reproduction

Each corpus has 54 cases spanning 32/64/128 MiB, ordinary/prefix streams, both
layouts, and compatible one/four/eight-core worker combinations. Five samples
per case give 540 total. All 108 cases were correct, had unchanged measured
source snapshots, stayed within the shared profiler's 30% CV bound, and were
`UNBASELINED` on their first attempt. No historical baseline approval or
regression-gate pass is claimed. Concurrency identity counts one sampler
process; each case separately declares and verifies its decoder-worker count.

Both matrices use optimized probe SHA-256
`7b9c0b27f8df3598b6ae901b6aa55aa7dce74c5c966733c20330b67fc09e5e06`
on Linux x86_64 with an AMD Ryzen Threadripper 3990X. `taskset` enforces affinity;
the main table uses CPUs 0–7, eight distinct physical cores. The admitting job
checked ancestor CPU quotas and found none. Each matrix used one `build-budget`
admission and the qualified Bubblewrap read-only-host boundary, with private
fixtures, HOME/XDG state, and history. Case order was shuffled with seed 44.
The experiment launched no compilation during sampling; the shared host was
not exclusive.

The mixed/repeated-new isolated totals were 107.57/107.68 seconds, including
30.91/29.78 seconds of fixture/reference setup. Resource-queue wait is separate.
Codec clocks are Rust `Instant` and checked host-generated
`CLOCK_PROCESS_CPUTIME_ID` bindings. Hyperfine 1.20.0 measures process wall;
GNU time 1.10 supplies process CPU at 0.01-second resolution and peak RSS.

[All 540 samples](../benchmarks/zstdz-parallel-apply-20261025-samples.csv) and
[fixture/frame identities](../benchmarks/zstdz-parallel-apply-20261025-fixtures.csv)
are preserved. Raw profiler envelopes contain local operational metadata and
remain outside public source.

```bash
./bm-parallel-apply > "$TMPDIR/parallel-mixed.json"
./bm-parallel-apply repeated-new > "$TMPDIR/parallel-repeated.json"
```

This Linux-only research command builds through Nix, then executes prepared
artifacts inside confinement. JSON goes to stdout and progress to stderr.
Exit 3 means valid unbaselined observations. Per-run private history does not
install a new regression baseline.
