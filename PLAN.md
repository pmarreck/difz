# ZDiff Implementation Plan

## Completed Tasks

- [x] Task 1: Project Scaffolding — flake.nix, build.zig, build.zig.zon, src/lib.zig, shell scripts, .gitignore (2026-02-25 ~10:30pm EST)
- [x] Task 2: Gear Hash — rolling hash with BLAKE3-seeded 256-entry u64 lookup table (2026-02-25 ~10:45pm EST)
- [x] Task 3: CDC — Content-Defined Chunking using Gear hash (2026-02-25 ~11:00pm EST)
- [x] Task 4: Chunk Matching — BLAKE3 fingerprinting, HashMap-based match finding (2026-02-25 ~11:15pm EST)
- [x] Task 5: Elder/Myers O(ND) Byte Diff — fine-grained byte-level diffing (2026-02-25 ~11:30pm EST)
- [x] Task 6: Two-Stage Diff Orchestrator — CDC coarse matching + Elder gap refinement (2026-02-25 ~11:45pm EST)
- [x] Task 7: BLIP Encoding — serialize diff instructions as BLIP ARRAY container (2026-02-26 ~12:00am EST)
- [x] Task 8: Patch — apply BLIP-encoded diff to reconstruct target (2026-02-26 ~12:15am EST)
- [x] Task 9: C FFI Layer — zdiff_diff, zdiff_patch, zdiff_free exports + zdiff.h (2026-02-26 ~12:30am EST)
- [x] Task 10: C CLI — C program dogfooding the FFI, 46 CLI integration tests (2026-02-26 ~12:45am EST)
- [x] Task 11: Benchmark Suite — hyperfine stats, zdiff vs bsdiff vs xdelta3 (2026-02-26 ~1:00am EST)
- [x] Task 12: Documentation — CODE_MINIMAP.md, PLAN.md, PROJECT_SPEC.md updates (2026-02-26 ~1:15am EST)

- [x] Task 13: Edit Distance Cap — cap Myers at sqrt(N+M)*2+16, bail to raw Insert on large dissimilar gaps (~170x speedup on 100KB/10% similar) (2026-02-26)

## Next Steps

- [x] ~~Performance optimization: Elder/Myers O(ND) is O(n*d) which is very slow for large dissimilar regions~~ — DONE: edit distance cap (Task 13)
- [ ] Diff size optimization: currently 3x larger than bsdiff/xdelta3 — investigate compression of insert data and more efficient encoding
- [ ] Progress indication: the Zig core currently provides no progress callbacks; need to add a callback mechanism for the C CLI to display stage progress
- [ ] Translation groundwork: lay foundation for 30-language support per AGENTS.md CLI guidelines
- [ ] Fuzzing suite: fuzz the encoder/decoder for robustness
- [ ] Cross-platform CI: test on Linux x86_64/aarch64 and Windows
