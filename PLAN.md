# ZDiff Implementation Plan

## Tasks

- [x] Task 1: Project Scaffolding — flake.nix, build.zig, build.zig.zon, src/lib.zig, shell scripts, .gitignore (completed 2026-02-25 ~10:30pm EST)
- [ ] Task 2: Gear Hash — rolling hash with BLAKE3-seeded 256-entry u64 lookup table
- [ ] Task 3: CDC (Content-Defined Chunking) — Gear hash CDC with configurable average chunk size
- [ ] Task 4: Chunk Matching — BLAKE3 fingerprinting of CDC chunks, match identical chunks between files
- [ ] Task 5: Elder/Myers O(ND) Byte Diff — fine-grained byte-level diffing for unmatched regions
- [ ] Task 6: Two-Stage Diff Orchestrator — CDC for coarse matching, Elder diff for gap refinement
- [ ] Task 7: BLIP Encoding of Diff Output — encode diff instructions as BLIP ARRAY container
- [ ] Task 8: Patch (Apply Diff) — apply a zdiff patch to reconstruct file B from file A
- [ ] Task 9: C FFI Layer — expose zdiff core through C-callable API with header
- [ ] Task 10: C CLI — C program that dogfoods the FFI for diff and patch operations
- [ ] Task 11: Benchmark Suite — hyperfine benchmarks comparing zdiff vs bsdiff vs xdelta
- [ ] Task 12: Documentation and Final Polish — CODE_MINIMAP.md, README, CLI help, --about
