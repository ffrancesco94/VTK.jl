# AGENTS.md — agent-facing notes for VTK.jl

This file complements README/STATUS with durable, agent-focused
implementation details and gotchas. Keep it current when the build pipeline or
workflow changes.

## Project shape

- Julia bindings for a subset of VTK 9.x, via CxxWrap. By default the C++
  wrapper comes from `VTK_julia_jll`; `VTKJL_LIB` overrides it with a local
  build. The wrapper sources are WrapIt-generated + merged shim, rebuilt by
  `julia --project=. gen/build_wrapper.jl`
  (driver: `gen/wrapit/build.jl`). It registers generic base-class methods
  (e.g. `GetOutput` on `vtkAlgorithm`) via the hand shim (`shim_vtkjl.cpp`)
  plus a generated auto-shim (`build/cxx/shim_auto.cpp`, produced by
  `gen/wrapit/auto_shim.jl` from VTK headers, factories + macro accessors
  like `InsideOutOn`). `gen/wrapit/smartptr_wrappers.jl` also generates
  `src/generated_methods.jl`, smart-pointer overloads that forward to the
  raw-pointer bindings through `_cp`; regenerate it after binding changes.
  The legacy hand-written CMake wrapper was removed 2026-10-29.
- Test counts: **181/181**.
- WrapIt is built **from source** from upstream `grasph/wrapit` (main), not
  from WrapIt_jll; see `gen/wrapit/wrapit_src.jl`. `VTKJL_WRAPIT_REPO` and
  `VTKJL_WRAPIT_REF` override the source; changing either triggers a rebuild.

## Gotchas (learned the hard way)

- **Local WrapIt builds on Ubuntu: Ubuntu splits LLVM into versioned dirs.**
  `libclang.so` lives in `/usr/lib/llvm-*/lib` (outside CMake's default
  `find_library` path) and the debs ship only *versioned*
  `libclang-cpp`/`libLLVM` — wrapit's CMake wants unversioned names. Derive
  `VTKJL_CLANG_PREFIX` from `clang -print-resource-dir` and symlink the
  versioned libs. Validated on ubuntu-latest with clang 21. Normal CI and
  documentation builds use `VTK_julia_jll` and do not need this toolchain.

- **Precompile cache does not track `VTKJL_LIB` or the .so content.** Always
  `rm -rf ~/.julia/compiled/v1.12/VTK` when switching libraries, or Julia may
  keep method tables from the previous lib.
- **`gen/wrapit/build/` and `wrapper/build/` are gitignored.** A stale
  shipped lib there does not reflect the committed driver; when test results
  disagree with the notes, rebuild from the entry point and diff artifacts
  (`build/cxx/shim_auto.cpp` must exist and `jlVTKGen.cxx` must call
  `register_auto_shim_methods`).
- **Downcast registry is automated**: `DOWNCAST_REGISTRY` (src/dataset.jl) is
  built at module load from `DOWNCAST_SOURCES` triples, filtered by what the
  loaded library actually registers. Adding a grid type = header in
  VTK.wit.in + `downcast_foo` shim binding + typed constructor —
  no registry edit. Only extend `DOWNCAST_SOURCES` for a genuinely new kind
  of type.
- The wrapit generation was validated with clang 13 (jll) and clang 22
  (system); other libclang versions may behave differently.
- **Release builds pin WrapIt**: `gen/wrapit/wrapit.pin` holds the full commit
  SHA, exported as `VTKJL_WRAPIT_REF` by the PublishWrapper workflow.
  `wrapit_src.jl` fetches SHAs directly (`git clone -b` only accepts
  branches/tags). The publish workflow also drops the not-yet-registered
  `VTK_julia_jll` compat bound for the `VTKJL_LIB` test run only (restored
  via trap), since the resolver cannot satisfy it before the JLL registers.
- Kaimon MCP Julia sessions are optional for this repo, but should be used
  when possible; plain `julia --project=...` works for builds/tests.

## Quick commands

```sh
# Build the wrapper (full pipeline incl. wrapit build, long)
julia --project=. gen/build_wrapper.jl

# Test (mind the precompile cache!)
rm -rf ~/.julia/compiled/v1.12/VTK
julia --project=test test/runtests.jl

# Low-level integration test for the generated module
julia --project=gen/wrapit gen/wrapit/generated_library_integration.jl

# Release the wrapper: (1) on main, commit the release prep — bump `version`
# and [compat] VTK_julia_jll in Project.toml to the new version (and update
# gen/wrapit/wrapit.pin if advancing wrapit); (2) tag that commit and push
# only the tag. The PublishWrapper workflow builds from the tag with wrapit
# pinned, requires a clean tracked tree after generation, tests against the
# fresh library (VTKJL_LIB), and pushes the generated sources to VTK_cxxwrap
# under the same tag via gen/publish_wrapper.jl (needs VTK_CXXWRAP_TOKEN);
# (3) point Yggdrasil's V/VTK_julia at the new commit and open the PR.
# Users: release tags get the prebuilt JLL; on main, build locally + VTKJL_LIB.
git tag v0.2.0 && git push origin v0.2.0
```
