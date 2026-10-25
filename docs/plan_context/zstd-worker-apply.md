# Worker encoding, ordinary compression, and diff application

The earlier [worker comparison](zstd-worker-modes.md) measured prefix-diff
creation. Its result cannot establish that ordinary compression benefits
little from workers, or that worker-produced diffs apply faster. Follow-up
controls on October 24, 2026 separate those questions.

## Findings

Ordinary compression benefited from four workers on the 32 MiB target.
Prefix-diff creation did not. These are means of three fresh CLI processes,
with affinity allowing 12 logical CPUs and explicit 8 MiB jobs in worker
mode. All times are elapsed wall time.

| Operation on 32 MiB target | Single-thread encoding | T1 encoding | T4 encoding |
| --- | ---: | ---: | ---: |
| Ordinary compression | 212.1 ms | 211.3 ms | 131.4 ms |
| Source-prefix diff creation | 211.0 ms | 311.3 ms | 283.4 ms |

Thus four workers reduced ordinary-compression elapsed time by 38% (1.61x
throughput), while increasing prefix-diff creation time by 34%. Ordinary
compression output was 16,812,788 bytes in single-thread mode and 16,812,740
bytes in either worker mode. Prefix frames were 2,106,735 and 2,106,723 bytes,
respectively. No 5–10% size penalty occurred on this particular input.

At 8 MiB, one job fits the entire target. Ordinary compression took 58.1,
59.5, and 62.6 ms in single-thread, T1, and T4 modes, respectively. Prefix
creation took 75.1, 135.1, and 127.7 ms. Every mode produced the same frame
bytes within each 8 MiB workload. Merely requesting four workers does not
give four jobs when only one job's worth of input is available.

Application was checked separately. A first three-sample pass suggested
73.82 ms for the single-thread-produced 32 MiB diff versus 67.90 ms for the
worker-produced diff. Their ranges overlapped. The 8 MiB application control
also shifted from 17.54 to 16.52 ms despite byte-identical inputs. This was
insufficient evidence of an encoding-mode effect, so a second, prospectively
defined experiment used 24 shuffled blocks and an identical-input control.

| 32 MiB operation, 12 allowed CPUs | Single-thread-produced input | Worker-produced input | Identical single-thread input control |
| --- | ---: | ---: | ---: |
| zstdz CLI prefix decode | 59.10 ms | 58.08 ms | 57.75 ms |
| Complete difz apply | 70.30 ms | 70.75 ms | 70.32 ms |

Each cell is the mean of 24 samples. Complete apply with affinity restricted
to one CPU likewise took 69.16 ms for the single-thread-produced patch and
69.29 ms for the worker-produced patch; its identical-input control took
69.78 ms. This experiment found no meaningful complete-apply benefit from
worker encoding. The small prefix-decode difference was less than the shift
seen between identical-input controls, so it does not establish a decoder
speed advantage either. This is finite evidence, not proof that another
input could never decode faster after worker compression.

## Why prefix creation scales differently

Both modes must process the source prefix as well as the target. Splitting
the target into jobs does not divide all of that work into independent,
equal-cost quarters. In the pinned implementation,
[`ZSTDMT_serialState_genSequences`](https://github.com/pmarreck/zstdz/blob/abaedb3e/lib/compress/zstdmt_compress.c)
serializes long-distance sequence generation under a mutex in job order.
The initialization path also builds a dictionary from the original prefix.
Workers then consume those sequences and perform their remaining compression
work. These are concrete serial stages; this investigation did not profile
their individual time shares, so no exact bottleneck percentage is claimed.

Ordinary compression in this experiment has no external prefix and does not
enable long-distance matching. It therefore has a different distribution of
serial and parallel work. Its measured speedup supports the expectation that
four smaller compression jobs can reduce elapsed time. Fourfold speedup is
not guaranteed, given overlap, setup, buffering, coordination, and memory
traffic.

## Implications for an updater

Current difz explicitly requests zero compression workers. That remains the
selected direction. A worker-produced zstdz stream still has one Zstandard
frame, and current apply calls the serial `ZSTD_decompressDCtx` API. Worker
count is an encoder parameter; it does not request multiple decoding workers
or supply an index of independently decodable jobs. See the
[Zstandard API](https://github.com/facebook/zstd/blob/dev/lib/zstd.h).

Different encoding choices can change decoder work even when the outputs
reconstruct the same target. That permits an incidental decode-speed change;
it provides no automatic multicore application gain. T1 and T4 produced
identical frames here, so a decoder receiving those identical bytes has no
compression-worker-count difference to act on. Parallel application across
independent files or independently decodable chunks would be a separate
design choice.

These measurements used warm files on a private RAM-backed filesystem. They
remove physical storage latency and are relevant to the proposed fast-storage
case. They do not simulate a particular SSD, cold cache, durable flush, or
whole application upgrade. Allocation, page faults, kernel copies, hashing,
and memory bandwidth still contribute. A large system-CPU share is not proof
of waiting on disk. Actual release pairs and native storage measurements
remain necessary before claiming an updater-wide bottleneck or universal
default advantage.

## Reproduction and retained evidence

The fixture is the same 50% seeded-random/50% zero-block construction as the
earlier experiment. The source uses seed 42; the target replaces the random
half of every eighth 4 KiB block with seed-43 bytes. This replaces 6.25% of
the file with new randomness. The 8 MiB and 32 MiB cases are prefixes of the
same generated pair. Source and target SHA-256 values and ordinary compression
controls are in [the fixture CSV](../benchmarks/zstdz-worker-control-20261024-fixtures.csv).

Creation commands use level 9, `--single-thread` or `-T1`/`-T4`, and
`--jobsize=8388608` for worker modes. Prefix cases add `--patch-from=SOURCE`;
ordinary cases do not. The 32 MiB target therefore gives four 8 MiB jobs.
All warmups and timed samples reconstruct the expected target and are byte
checked outside timing. All worker outputs are byte checked against the
same T1 reference. The 72 creation samples are retained in
[the creation CSV](../benchmarks/zstdz-worker-control-20261024-samples.csv).

The first application pass used the ordinary and prefix frames from the
same construction. It measured codec CLI decode and complete difz apply as
separate cases at 8 MiB and 32 MiB, with one-CPU and 12-CPU affinity. Its 72
samples are retained in [the initial application CSV](../benchmarks/zstdz-worker-apply-20261024-samples.csv).

For complete apply, the prepared difz oracle generated each 85-byte ZDIF v4
header independently, including the source and target BLAKE3 identities and
lengths. The corresponding single-thread or worker-produced prefix frame
replaced only the payload. Every complete application passed difz's own
identity checks and an external byte comparison against the target. The
complete 32 MiB patch sizes were 2,106,820 and 2,106,808 bytes. Apply timing
includes input reading, allocation, hash verification, reconstruction, and
writing the output; external byte comparison and fresh-output preparation
are outside the timed interval.

The paired follow-up measures only the 32 MiB prefix decode and complete
apply, with one-CPU and 12-CPU affinity as separate cases. Each case has 24
blocks containing three treatments: `st`, `mt`, and `same`. `same` invokes
the exact same command and patch path as `st`. Within each block the three
labels are shuffled using `random --seed (42 + block_number) --shuffle`,
with block numbers 1 through 24. The same precomputed order is used for each
case. Three verified warmups precede measurement. The actual order and all
288 sample values are retained in
[the paired CSV](../benchmarks/zstdz-worker-apply-paired-20261024-samples.csv).

The paired adapter uses the pinned profiler's process runner and luv monotonic
clock around GNU time and a fresh CLI process. Parent GC settles before each
sample. This includes process-runner overhead and uses no startup subtraction;
it is a distinct measurement definition from the initial hyperfine pass.
GNU time reports user/system CPU at 0.01-second resolution and process peak
RSS. The shared profiler evaluates the `st` series as its declared timing
metric and retains all three variants as diagnostic data; no separate
historical gate is claimed for the contrasts.

All experiments used the same Linux x86_64 CPU and optimized pinned zstdz
artifact as [the earlier measurement](zstd-worker-modes.md). The complete
apply executable was prepared through Nix and had SHA-256
`d0fca232ee6328b4d7303a65104dc05223332a0cce06ada991fc455112683e89`.
Each experiment ran in one bounded `build-budget` job under Bubblewrap with
a read-only host and private writable fixtures and history. A checkout-write
canary was rejected. The measured Git source fingerprint stayed unchanged.
Every case completed on its first measurement attempt, below the configured
30% coefficient-of-variation limit; all were `UNBASELINED`, with no approved
historical epoch. This is not a statistical equivalence test or a regression
gate pass.

Creation setup took 9 seconds and isolated execution took 36 seconds total.
The initial successful application pass took 9 seconds of setup and 20
seconds total. Its first setup attempt had stopped before timing because
envelope assembly preceded fixture initialization; no samples from that
attempt were retained as measurements. The paired experiment took 9 seconds
of setup and 37 seconds total. These totals include preparation and
verification, rather than presenting kernel execution alone as feedback time.
