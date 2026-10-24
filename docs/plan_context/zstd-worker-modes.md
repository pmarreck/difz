# zstdz worker-mode measurements

On this synthetic prefix-diff workload, `--single-thread` was faster than
`-T1`, `-T4`, and `-T8` at every measured size. Worker modes produced identical
bytes across worker counts, CPU allowances, warmups, and timed repetitions.
Their 64 MiB patch was 32 bytes smaller than the single-thread patch; the
4 MiB and 16 MiB patches were identical across all modes.

These are local measurements from October 24, 2026, using the optimized CLI
built from the project's pinned zstdz revision `abaedb3e` (reports Zstandard
1.6.0). This measures the codec's CLI prefix path. It does not measure difz's
BLAKE3 work, patch envelope, in-memory API, or filesystem publication.

## Results

Each cell below is the arithmetic mean of three fresh CLI processes with
warm files. CPU affinity allowed 12 logical CPUs. RSS is the mean of the
three process peak readings, rather than an allocation count or leak measure.
`st` means `--single-thread`; the other modes request that many workers.

| Input MiB | Mode | Patch bytes | Wall ms | User CPU s | System CPU s | Peak RSS MiB |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 4 | st | 263,277 | 41.7 | 0.020 | 0.010 | 20.0 |
| 4 | T1 | 263,277 | 71.1 | 0.040 | 0.020 | 20.3 |
| 4 | T4 | 263,277 | 68.3 | 0.040 | 0.020 | 20.2 |
| 4 | T8 | 263,277 | 63.4 | 0.037 | 0.020 | 20.0 |
| 16 | st | 1,053,233 | 145.3 | 0.107 | 0.023 | 47.0 |
| 16 | T1 | 1,053,233 | 231.4 | 0.177 | 0.047 | 47.2 |
| 16 | T4 | 1,053,233 | 216.7 | 0.183 | 0.057 | 57.1 |
| 16 | T8 | 1,053,233 | 208.9 | 0.177 | 0.057 | 56.6 |
| 64 | st | 4,213,667 | 351.2 | 0.237 | 0.103 | 154.7 |
| 64 | T1 | 4,213,635 | 452.8 | 0.323 | 0.170 | 154.6 |
| 64 | T4 | 4,213,635 | 388.2 | 0.397 | 0.180 | 186.9 |
| 64 | T8 | 4,213,635 | 383.4 | 0.430 | 0.217 | 225.6 |

At 64 MiB, T1 used about 45% more total CPU time and took 29% longer than
single-thread mode. T8 reduced the wall time relative to T1, but still took
9% longer than single-thread mode, used about 90% more total CPU time, and
increased mean peak RSS by 46%. The worker-mode patch saving was approximately
0.00076% of patch size. This provides no size or efficiency reason to change
difz's current zero-worker setting for this workload.

The separate one-logical-CPU cases also favored single-thread mode:

| Input MiB | st ms | T1 ms | T4 ms | T8 ms |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 46.9 | 70.7 | 71.5 | 69.7 |
| 16 | 142.4 | 246.0 | 253.4 | 242.1 |
| 64 | 352.0 | 517.5 | 543.0 | 552.1 |

All 72 timed samples, including CPU affinity, CPU time, RSS, patch length,
and patch SHA-256, are in
[the sample CSV](../benchmarks/zstdz-worker-modes-20261024-samples.csv).
[The fixture CSV](../benchmarks/zstdz-worker-modes-20261024-fixtures.csv)
records source and target identities and ordinary-compression controls.

## Workload and verification

Generate 32 MiB of deterministic random bytes with
`random --seed 42 -b -c 33554432` and 4 MiB of replacement bytes with
`random --seed 43 -b -c 4194304`. The pinned `random` 0.3.0 uses a seeded
BLAKE3 keyed XOF. Its executable SHA-256 was
`a37be50afe6b3379016674f4c017e12da3faf503fe2537894bdcc7440a648aa6`.

Construct a 64 MiB source from 16,384 blocks. Each block contains the next
2,048 source-random bytes followed by 2,048 zero bytes. The target has the
same layout, with the random half of block indices 0, 8, 16, and so on
replaced by the next 2,048 replacement bytes. Thus 12.5% of blocks change,
and replacement randomness occupies 6.25% of the entire file. Smaller cases
are the first 4 MiB and 16 MiB of this pair. This fixes the byte distribution
and edit fraction across sizes. Ordinary level-9 single-thread compression
of each target produced approximately 50.11% of its original size.

For each size and mode, run:

```bash
zstd -q -f -9 MODE --patch-from=SOURCE TARGET -o PATCH
zstd -q -f -d --patch-from=SOURCE PATCH -o REBUILT
cmp TARGET REBUILT
```

`MODE` is `--single-thread`, `-T1`, `-T4`, or `-T8`. No adaptive mode,
explicit job size, dictionary training, or additional compression tuning is
used. Every warmup and timed compression is independently decoded and byte
compared with the target. Verification runs outside the timed interval.
Every result is also byte compared with a precomputed reference for its
size and mode family, with all worker counts sharing the T1 reference.
The three reference frame SHA-256 values for worker mode are:

| Input MiB | Worker-mode patch SHA-256 |
| ---: | :--- |
| 4 | `dbd70c54c3c470046700dfe49b7e41cd88d737d5002ad626588a4f725ce66d6d` |
| 16 | `837b57a746b4d5c0a092cdd79bb3084fdca98064ea083b4cb46fa6318a5bff29` |
| 64 | `658dc4524ed8630095afd78d71b6674c1d890e9e48c62f3791a3f074fbc89d82` |

## Multi-job coverage

The verbose CLI diagnostic reported level-9 defaults `chainLog=20`,
`strategy=ZSTD_lazy2`, automatic job size, and automatic activation of long
distance matching for the 64 MiB prefix case. The patch path raises the
window log to 27. In the pinned implementation,
[`ZSTDMT_computeTargetJobLog`](https://github.com/pmarreck/zstdz/blob/abaedb3e/lib/compress/zstdmt_compress.c)
uses `max(21, cycleLog + 3)` when long distance matching is enabled.
Here `cycleLog=20`, giving 8 MiB jobs. Default overlap is 512 KiB and does
not increase the job size. Thus the 16 MiB and 64 MiB cases exceed one job;
the 4 MiB case fits within one. These job dimensions are derived from the
pinned source and parameters; the optimized binary has no per-job trace.

The unchanged frame bytes at 16 MiB therefore do not establish that the
single-thread and worker algorithms are identical. The 64 MiB case directly
demonstrates their output difference while retaining agreement among worker
counts. This finite experiment does not guarantee byte identity across
codec versions, other encoders, settings, or inputs.

## Measurement provenance and limits

- Hardware was an AMD Ryzen Threadripper 3990X, Linux x86_64. `taskset`
  enforced CPU 0 for single-CPU cases and CPUs 0 through 11 for the other
  cases. Those are affinity allowances, not a claim that all CPUs were busy.
- The codec was built through `nix build .#zstd-benchmark`, with optimized
  upstream build defaults. The artifact was already cached; this run
  required no codec compilation. Executable SHA-256 was
  `a9e5cffc8cef497cbbf783fd2be784a262b4e45cdf4e73e4bed23e1a915e2aa7`.
- The project's pinned `performance-profile` ran 24 separate cases with
  `cores: 1` or `cores: 12`. Each adapter performed one verified warmup
  and three hyperfine 1.20.0 samples, using GNU time 1.10 for process CPU
  and peak RSS. Wall time includes the fresh process and GNU time wrapper;
  no guessed startup cost was subtracted. CPU seconds have 0.01-second
  resolution, so small-case CPU ratios are coarse.
- A frozen disposable Git project held the adapters and configuration.
  Its source fingerprint stayed unchanged across the run. Each case
  completed on its first attempt with sample coefficient of variation
  below the configured 30% limit. All were `UNBASELINED`, because this was
  a new experiment without approved history. No historical gate or baseline
  approval is claimed.
- One `build-budget` admission covered runtime setup and measurements.
  No queue wait was reported. Bubblewrap mounted the host read-only and
  supplied private writable fixtures, outputs, HOME, and history; a write
  canary confirmed that the checkout could not be modified. Fixture and
  reference preparation took 10 seconds; total isolated execution took
  46 seconds, including 36 seconds for the profiler and measurement work.
- The public CSVs preserve the measurements without publishing private host
  metadata from the raw profiler records. The results cover one synthetic
  edit distribution, one seed pair, one machine, and sizes through 64 MiB.
  Other edit patterns, larger files, and difz's complete in-memory lifecycle
  need their own measurements before changing the product default.
