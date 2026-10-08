# PLAN

Completed work is retained in docs/PLAN_LOG.md; measurement details live in docs/plan_context/.

## Active

- [x] Build the benchmark zstd CLI from the zstdz URL pinned in build.zig.zon; check that the dev shell uses that source. (done 2026-10-08 08:25 EDT, b3e9a9d)
- [x] Add a verified CDC-versus-zstd benchmark adapter and the shared-profiler matrix for three edit shapes, nine sizes, and two core counts. (done 2026-10-08 08:34 EDT)
- [x] Give each benchmark size an independent case and fix profiler deadlines to terminate the complete workload process group. (done 2026-10-08 08:54 EDT)
- [ ] Compare the preserved CDC engine with the zstd engine across file sizes, controlled edit patterns, and available real release pairs; verify outputs and report time, peak memory, and patch-size tradeoffs.
- [ ] Remeasure the cached ISO pair warm with difz and the pinned CLI in single-thread and T1 modes; verify every reconstruction and record wall, user, system, RSS, and patch bytes.
- [ ] Explain any remaining same-source performance gap with isolated measurements before changing compression concurrency.
- [x] Record existing project purpose and the preference for a simpler zstd engine in INTENT.md. (done 2026-10-08 08:25 EDT)
- [ ] Commit the verified comparison on this branch; preserve the CDC branch and do not push.
- [ ] If the zstd engine is adopted, preserve the CDC tip as old-cdc-plus-compression-probe-design and make the tested zstd implementation yolo; keep both local unless publication is requested.
- [ ] Immediately after the engine decision, complete the remaining DIFZTREE v2 metadata work; API compatibility with the old design is not required because there are no upstream consumers. (context: docs/plan_context/metadata-v2.md)
- [x] Branch a per-file zstd --patch-from engine that keeps BLAKE3 checks and DIFZTREE outside and drops CDC plus compression selection. (done 2026-10-08 12:31am EDT)
- [x] Remeasure the branch on the same ISO pair. Keep the CDC engine reachable from the pre-change commit if the branch wins. (done 2026-10-08 12:36am EDT)
- [x] Repin random to a758c902143f8f1dc08c3f33964b8fde7e4a2218 so the dev-shell CLI streams past 1 GiB. (done 2026-10-07 4:59pm EDT)
- [x] Measure a 1024 MiB uniform full-replace: zstd level 3 did not shrink it and -T0 did not beat -T1. (done 2026-10-07 4:59pm EDT)
- [x] Remeasure the shared-prefix rows and the Neovim AppImage pair with the `./bm` method. The August Validate ELFs were not available and were not rebuilt. (done 2026-10-07 9:40am EDT)
- [x] Split create time between the matcher and the `--compress best` probe. On a pinned seed, `best` matched LZMA2 or uncompressed, and the probe was the extra cost. (done 2026-10-07 10:08am EDT)
- [ ] Make `--max-rss-bytes` enforceable on Darwin. `setrlimit(RLIMIT_AS)` returns EINVAL, so difz exits before create. The PDFPals run stayed under 8 GiB when observed with `/usr/bin/time -l`. (context: docs/plan_context/mac-archive-oracle.md)

## Recently completed (2026-09-29)
