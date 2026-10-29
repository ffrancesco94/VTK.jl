# AGENTS.md — agent-facing notes for VTK.jl

This file complements README/STATUS/SESSION_NOTES with durable, agent-focused
implementation details and gotchas. Keep it current when the build pipeline or
workflow changes.

## Project shape

- Julia bindings for a subset of VTK 9.x, via CxxWrap. Two C++ wrapper
  variants, both landing at `wrapper/build/libvtk_julia.so` (the default load
  path in `src/VTK.jl`; override with `ENV["VTKJL_LIB"]`):
  - **Default**: WrapIt-generated + merged shim library, built by
    `julia --project=. gen/build_wrapper.jl` (driver: `gen/wrapit/build.jl`).
    It registers generic base-class methods (e.g. `GetOutput` on
    `vtkAlgorithm`) via the hand shim (`shim_vtkjl.cpp`) plus a generated
    auto-shim (`build/cxx/shim_auto.cpp`, produced by `gen/wrapit/auto_shim.jl`
    from VTK headers, factories + macro accessors like `InsideOutOn`).
    `gen/wrapit/smartptr_wrappers.jl` also generates
    `src/generated_methods.jl`, smart-pointer overloads that forward to the
    raw-pointer bindings through `_cp`; regenerate it after binding changes.
  - **Fallback**: legacy hand-written CMake wrapper,
    `julia --project=. gen/build_wrapper_cmake.jl`. Lacks the auto-shim.
- Test counts: **170/170 on the merged lib** (15 CFD-reader + 10 legacy-VTK + 2 calculator + auto-shim tests),
  **96/96 on the hand-written fallback** (auto-shim, CFD, legacy, and calculator testsets self-skip via
  `isdefined(VTK, :InsideOutOn)` / `isdefined(VTK, :EnSightGoldReader_new)` / `isdefined(VTK, :GenericDataObjectReader_new)` / `isdefined(VTK, :ArrayCalculator_new)`).
- WrapIt is built **from source** from the fork `ffrancesco94/wrapit` (main),
  not from WrapIt_jll; see `gen/wrapit/wrapit_src.jl`. The upstream bugs we
  patched are documented in `docs/wrapit-upstream-bugs.md`.

## Gotchas (learned the hard way)

- **CI (ubuntu-latest): Ubuntu splits LLVM into versioned dirs.** `libclang.so`
  lives in `/usr/lib/llvm-*/lib` (outside CMake's default `find_library` path)
  and the debs ship only *versioned* `libclang-cpp`/`libLLVM` — wrapit's CMake
  wants unversioned names. Both workflows derive `VTKJL_CLANG_PREFIX` from
  `clang -print-resource-dir` and symlink the versioned libs. Validated on
  ubuntu-latest with clang 21 (works despite local validation being on 13/22).

- **Precompile cache does not track `VTKJL_LIB` or the .so content.** Always
  `rm -rf ~/.julia/compiled/v1.12/VTK` when switching libraries, or Julia may
  keep method tables (e.g. `GetOutput`, `InsideOutOn`) from the previous lib.
- **CMake caches absolute Julia paths.** `wrapper/build/CMakeCache.txt` pins
  `Julia_INCLUDE_DIRS`/`Julia_LIBRARY` to the juliaup version that ran
  `cmake -S`. After a Julia update, `--clean-first` is not enough (configure
  fails on `julia.h`) — delete `wrapper/build` and re-run
  `gen/build_wrapper_cmake.jl`.
- **`--clean-first` can silently skip relinking** if a copied-in .so is newer
  than the objects: the suite then runs against the *previous* lib and prints
  misleading results. For an honest A/B, delete the build dir (or touch the
  sources) and verify `strings libvtk_julia.so | grep InsideOutOn` (merged)
  or absence (fallback) before trusting test counts.
- **`gen/wrapit/build/` and `wrapper/build/` are gitignored.** A stale
  shipped lib there does not reflect the committed driver; when test results
  disagree with the notes, rebuild from the entry point and diff artifacts
  (`build/cxx/shim_auto.cpp` must exist and `jlVTKGen.cxx` must call
  `register_auto_shim_methods`).
- **A/B discipline**: `isdefined(VTK, :InsideOutOn)` after `using VTK` is the
  fastest check of which variant is loaded.
- **Downcast registry is automated**: `DOWNCAST_REGISTRY` (src/dataset.jl) is
  built at module load from `DOWNCAST_SOURCES` triples, filtered by what the
  loaded library actually registers. Adding a grid type = header in
  wrapit.toml.template + `downcast_foo` shim binding + typed constructor —
  no registry edit. Only extend `DOWNCAST_SOURCES` for a genuinely new kind
  of type.
- The wrapit generation was validated with clang 13 (jll) and clang 22
  (system); other libclang versions may behave differently.
- Kaimon MCP Julia sessions are optional for this repo; plain
  `julia --project=...` works for builds/tests.

## Quick commands

```sh
# Default (merged) wrapper, full pipeline incl. wrapit build (long)
julia --project=. gen/build_wrapper.jl

# Fallback hand-written wrapper
rm -rf wrapper/build && julia --project=. gen/build_wrapper_cmake.jl

# Test (mind the precompile cache!)
rm -rf ~/.julia/compiled/v1.12/VTK
julia --project=test test/runtests.jl

# Conformance smoke test for the generated module
julia --project=gen/wrapit gen/wrapit/conformance.jl
```
