# CDC versus zstd file engine, 2026-10-08

The zstd engine creates patches faster and uses less peak memory in this measured size sweep. CDC retains a small patch-size advantage on some large moved-content and replacement inputs. Apply is substantially faster for scattered edits and full replacement; moved-content apply is often close. These results support choosing zstd for the simpler architecture, without claiming it wins every input.

## Engines and method

Both executables are native Linux x86_64 ReleaseFast builds. CDC is commit `a83c0412446d55c82f490d46cdb2ee1d02a2d2a2`, with `--compress best` and a fixed CDC seed of 32 bytes of `0x2a`. The new engine's production source is commit `44dfd0f`; the benchmark tooling is commit `ca519ee`. Its only compressor is zstdz at `abaedb3e`, level 9, with `nbWorkers=0`. Relative to the CDC revision, the engine change removes a net 2,914 lines under `src/`, including eight retired matcher/container adapters. This count includes tests embedded in Zig source.

The machine has an AMD Ryzen Threadripper 3990X, 128 logical CPUs. Each case permits either CPU 0 alone or CPUs 0–11 through Linux affinity. The machine is shared, with other workloads observed during the campaign; CPUs were not reserved exclusively. Small timing differences and noisy samples should not be interpreted as precise rankings. Allowing 12 CPUs does not make the new engine's compression parallel.

`nix develop -c ./bm-engines` runs 108 cases: two engines, three edit patterns, nine sizes from 1 to 256 MiB by doubling, and two CPU configurations. Seed 42 generates the source and seed 43 generates replacement bytes. Patterns are:

- **Scattered:** replace every zero byte with `0x01`, changing about 1/256 of a uniform stream.
- **Moved:** rotate the source by one quarter, then replace the final eighth with fresh bytes.
- **Replacement:** replace the entire source with an independent uniform stream.

Fixture construction and verification are outside timing. Each case warms create and apply, then records three whole-process samples of each. Every timed create is followed by an untimed apply and byte comparison; every timed apply is followed by a byte comparison. All four engine/CPU combinations use identical input hashes for each shape and size. The executable hashes are constant for each engine.

The tables use the median wall time and maximum observed process RSS of three samples. GNU time reports CPU time at 0.01-second resolution. Very short processes sometimes have no RSS observation; those samples remain null. RSS is neither an allocation count nor evidence of leak freedom. Each difz process has a 120-second deadline and a 16 GiB address-space ceiling, despite the CLI flag's `--max-rss-bytes` name. The full case deadline is 600 seconds.

All 108 selected shared-profiler records are `UNBASELINED`, have successful reconstruction checks, and have matching before/after source snapshots within each case. No baseline epoch was accepted. One case invalidated by a concurrent PLAN.md edit was excluded and rerun. Earlier timeout diagnostics and the aborted campaign are also excluded. Immutable raw records remain in the configured external history; public CSVs contain measurements and hashes without local paths or machine identifiers.

The [summary CSV](../benchmarks/engine-comparison-20261008.csv) includes all 108 cases, means, medians, CPU time, RSS, patch bytes, fixture hashes, executable hashes, and external record IDs. The [sample CSV](../benchmarks/engine-comparison-20261008-samples.csv) includes all 648 timed process samples. The shared profiler compares per-size means; the tables below explicitly use medians for descriptive comparison.

## One-core size sweep

Each metric cell is **CDC / zstd**. Times are milliseconds, RSS is MiB, and patch sizes are bytes. These patterns are controlled experiments, not a model of the distribution of software updates.

| Pattern | Target MiB | Create ms | Create peak MiB | Patch bytes | Apply ms |
|---|---:|---:|---:|---:|---:|
| moved | 1 | 91.11 / 19.94 | 22.62 / 12 | 144869 / 131260 | 2.84 / 2.86 |
| moved | 2 | 229.15 / 31.54 | 47.19 / 14.1 | 271999 / 262426 | 4.84 / 4.69 |
| moved | 4 | 302.23 / 49.79 | 71.1 / 18.1 | 541772 / 524758 | 8.97 / 8.36 |
| moved | 8 | 795.89 / 374.31 | 143.1 / 28.1 | 1063515 / 1049430 | 33.31 / 20.74 |
| moved | 16 | 726.83 / 161.63 | 159.1 / 47.1 | 2109547 / 2098862 | 34.79 / 33.95 |
| moved | 32 | 1241.57 / 232.12 | 191.1 / 85.1 | 4208248 / 4197630 | 69.71 / 65.85 |
| moved | 64 | 2274.54 / 320.43 | 254.62 / 161.1 | 8401506 / 8395166 | 142.49 / 131.27 |
| moved | 128 | 4413.99 / 589.7 | 392.56 / 313.1 | 16793542 / 16790238 | 273.73 / 275.41 |
| moved | 256 | 8966.27 / 1061.14 | 764.93 / 617.1 | 33575626 / 33580382 | 562.36 / 546.26 |
| replacement | 1 | 150.43 / 21.2 | 39 / 13 | 1048756 / 1048694 | 3.84 / 3.04 |
| replacement | 2 | 168.72 / 30.4 | 47.1 / 15.1 | 2097332 / 2097294 | 6.61 / 4.81 |
| replacement | 4 | 201.63 / 60.37 | 65.1 / 22.1 | 4194484 / 4194494 | 11.8 / 9.07 |
| replacement | 8 | 261.29 / 114.3 | 101.1 / 35.1 | 8388788 / 8388894 | 23.08 / 19.77 |
| replacement | 16 | 376.23 / 202.26 | 173.1 / 61.1 | 16777404 / 16777694 | 46.78 / 36.8 |
| replacement | 32 | 612.79 / 316.41 | 316.82 / 113.1 | 33554620 / 33555294 | 95.76 / 71.28 |
| replacement | 64 | 1003.01 / 529.18 | 605.2 / 217.1 | 67109052 / 67110494 | 184.38 / 139.42 |
| replacement | 128 | 1920.82 / 1004.89 | 1181.19 / 425.1 | 134217916 / 134220894 | 378.87 / 254.48 |
| replacement | 256 | 4287.05 / 2018.44 | 2333.2 / 841.1 | 268435644 / 268441694 | 1066.13 / 568.11 |
| scattered | 1 | 127.88 / 22.04 | 28.01 / 12 | 28564 / 14464 | 7.29 / 2.93 |
| scattered | 2 | 227.64 / 34.83 | 39.77 / 13.1 | 56403 / 29423 | 11.85 / 4.94 |
| scattered | 4 | 455.02 / 72.1 | 72.27 / 18.1 | 119235 / 59754 | 23.98 / 9.92 |
| scattered | 8 | 788.68 / 106.66 | 144.45 / 27.1 | 237840 / 121403 | 47.16 / 17.93 |
| scattered | 16 | 1426.57 / 203.59 | 162.93 / 45.1 | 482255 / 248326 | 92.32 / 35.59 |
| scattered | 32 | 2582.86 / 296.41 | 200.32 / 81.1 | 898145 / 507387 | 186.28 / 69.33 |
| scattered | 64 | 5803.11 / 503.2 | 330.44 / 154.1 | 1776690 / 1036016 | 368.56 / 136.26 |
| scattered | 128 | 13352.59 / 931.67 | 536.12 / 299.1 | 3742774 / 2118998 | 737.08 / 283.55 |
| scattered | 256 | 25788.33 / 1852.74 | 984.3 / 589.1 | 7618469 / 4317631 | 1533.51 / 635.4 |

Across the one-core sweep, creation is 5.8–14.3× faster for scattered edits, 2.1–8.5× faster for moved content, and 1.9–7.1× faster for full replacement. Peak creation RSS is lower throughout. Scattered-edit patches are 41.7–49.9% smaller. The 256 MiB moved-content patch grows by 4,756 bytes (0.0142% of the CDC patch); the 256 MiB replacement patch grows by 6,050 bytes (0.0023%).

The 8 MiB moved-content creation step is slower than the 16 MiB step for both engines. The timings alone do not isolate parameter effects from shared-host noise, so a smooth scaling curve would be an unsupported interpretation. Three samples are evidence about these inputs, not a complexity proof.

## CPU allowance

The CSV includes all 12-CPU results. At 64 MiB scattered edits, CDC creation improves from 5,803 ms on one CPU to 3,252 ms with 12 CPUs; zstd changes from 503 ms to 495 ms. CDC's extra parallelism does not erase the creation-time gap. Full replacement and moved content show little consistent benefit from the larger allowance. The 256 MiB zstd replacement run is slower with 12 allowed CPUs (3,507 ms versus 2,018 ms), despite single-threaded compression; background load and the raw samples limit interpretation of that difference.

## Public release pair

The same adapter measured Neovim's Linux x86_64 AppImage releases [v0.11.3](https://github.com/neovim/neovim/releases/download/v0.11.3/nvim-linux-x86_64.appimage) to [v0.11.4](https://github.com/neovim/neovim/releases/download/v0.11.4/nvim-linux-x86_64.appimage), 10,996,216 to 11,012,600 bytes. Source SHA-256 is `5f377dc48c49a4170bd698a80ef461a702b8ebb8b2f7ddbb776341503d36415f`; target SHA-256 is `79e7e160f9505819a5e12f3d9366be94213f5309fb912ef4ef3af52df3982977`.

| CPUs | Engine | Create ms | Apply ms | Create peak MiB | Patch bytes |
|---:|---|---:|---:|---:|---:|
| 1 | CDC | 1,628.28 | 64.46 | 182.24 | 5,343,722 |
| 1 | zstd | 127.63 | 24.06 | 38.08 | 5,341,984 |
| 12 | CDC | 1,035.19 | 54.68 | 384.24 | 5,344,292 |
| 12 | zstd | 125.37 | 24.59 | 38.08 | 5,341,984 |

Here zstd creates 8.3–12.8× faster and writes a slightly smaller patch. CDC's patch and RSS vary between CPU configurations even with the seed fixed. The [Neovim measurement records](../benchmarks/neovim-engine-comparison-20261008.json) retain all samples and input hashes. These are three-sample diagnostics using the same verified adapter, separate from the 108 shared-profiler cohorts. The historical Validate ELFs remain unavailable and were not rebuilt.

## Same-source ISO comparison

The cached NixOS minimal ISO pair is 1,706,262,528 → 1,709,604,864 bytes. Source SHA-256 is `d74cb1858a7d8350506bc8889cdc291de6241157c402c9b814a8d817eac8ace9`; target SHA-256 is `bc64e5ccb058c7143c3803ad5ded61564d82509b0c13bcf572d012e82ecf3e4e`. All reconstructions matched, and each mode's final reconstruction SHA-256 matched that target.

These warm-file diagnostics ran sequentially after the matrix, with CPUs 0–11 allowed, one warmup and three create/apply samples per mode. GNU time measured the complete process. Every timed create was independently applied and compared outside timing. The [ISO sample CSV](../benchmarks/iso-same-source-20261008.csv) records all 18 samples. The CLI executable SHA-256 is `a9e5cffc8cef497cbbf783fd2be784a262b4e45cdf4e73e4bed23e1a915e2aa7`.

The CLI and difz both use zstdz `abaedb3e`, derived from the same `build.zig.zon` URL. The CLI is built through upstream's Makefile, while difz links the Zig-built C library; source provenance matches, compiler recipes differ. The fork's changes relative to [its upstream merge base](https://github.com/pmarreck/zstdz/compare/6e1e545916eff6457e4b264f8813a7417510a57e...abaedb3e) are wrapping/build/docs changes, with no changes under `lib/` or `programs/`.

CLI create uses `-9 --long=31 --patch-from=SOURCE`, changing only `--single-thread` versus `-T1`. Decode uses `--single-thread -d --long=31 --patch-from=SOURCE`. The compression thread flag does not establish single-threaded decoding or I/O; the recorded process CPU time can exceed wall time. CLI frames retain their default checksum. Difz includes its 85-byte identity header in the reported patch size.

| Mode | Create wall s | Create user / system s | Create peak MiB | Patch bytes | Apply wall s | Apply user / system s | Apply peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| difz | 8.89 | 7.78 / 1.04 | 4,054.01 | 557,171,921 | 3.06 | 1.39 / 1.52 | 3,787.07 |
| CLI `--single-thread` | 10.63 | 7.24 / 3.28 | 3,524.01 | 557,181,299 | 3.22 | 0.59 / 3.75 | 3,260.01 |
| CLI `-T1` | 11.04 | 7.79 / 4.85 | 3,538.79 | 557,813,501 | 3.05 | 0.56 / 3.69 | 3,260.01 |

Wall, user, and system columns are separate medians; adding medians need not equal the median of per-sample CPU sums. Peak RSS is the maximum sample.

Switching only CLI mode adds 632,202 bytes. That accounts for 98.5% of the previously reported 641,580-byte gap between difz and the older 1.5.7 `-T1` result. The same-source `-T1` frame has exactly the same size as that historical frame. Version alone was an unsupported explanation of that gap. A remaining 9,378-byte difference between difz and the single-thread CLI has not been isolated to a specific streaming or parameter difference; matching source pins does not promise identical frames.

The earlier CLI wall-time advantage was not reproduced. Current difz uses more peak RSS than either CLI mode, so matching library sources does not remove the whole-buffer adapter's memory cost. The shared host and changing I/O costs prevent attributing every timing difference to one cause. There is no measured reason here to add compression concurrency to difz.

The old CDC ISO result remains a historical single sample: 925.5 seconds creation, 35.1 GiB peak RSS, 662,865,660 patch bytes, and 9.34 seconds apply. It was not repeated with the current 16 GiB address-space ceiling, which is below that historical RSS. The new ISO patch is 15.9% smaller. Comparing 925.5 seconds with the new warm median suggests a roughly 104× creation improvement, but the methods and resource limits differ; it is not a fresh paired speedup measurement.

## Decision limits

The new implementation rejects either input above 2 GiB. It deliberately breaks the old file format and API, and keeps one fixed compression level. Directory metadata correctness remains a separate DIFZTREE v2 task. Neither the synthetic sweep nor two release pairs proves universal superiority. CDC remains worth preserving as a recoverable branch, while these measurements favor the simpler zstd implementation for the current default.
