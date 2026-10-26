# Session notes — where I stopped and what is missing

Date: 2026-10-26 (evening). This is a handover for the next session; delete
once the items below are done.

## State at commit (all verified locally unless noted)

- **WrapIt fork**: `ffrancesco94/wrapit` PR **#1 merged** into `main`
  (merge commit `2b00ffc`), containing the validated Bug-1 fix
  (null-`CXString` guard) + the clang-22 build fix. Feature branch
  `fix-null-cstring-truncation` **kept** as requested.
- **Driver builds wrapit from source** (`gen/wrapit/wrapit_src.jl`) from
  that fork; `WrapIt_jll` dependency removed. New build requirements
  (git/CMake/libclang/OpenSSL) are documented and installed in CI/docs
  workflows via apt.
- **Bug-1 veto loop deleted**; `veto.txt` is now 11 hand-maintained lines
  (ostream/bug-4 + getter regexes) + mechanically re-derived clash vetoes
  (~65 entries, self-healing via `veto_shim_clashes!()`).
- Generation now emits **1675 methods** (was 1397); auto-shim emits **25
  methods for 18 classes** (282 skipped because WrapIt generates them).
- **Verified on the merged lib**: full entry point
  `julia --project=. gen/build_wrapper.jl` → suite **97/97**, conformance
  **PASSED**. Earlier runs: suite 97/97 also via explicit `VTKJL_LIB`.
- **Hand-written CMake fallback**: suite **91/91** was verified before the
  fork change (generic plumbing + `upcast_dataarray` backport included);
  auto-shim testset skips there with an `@info` line.
- CI/docs YAML updated but **not yet exercised by CI** (see below).

## Exact place where I stopped

I had just noticed that the **last hand-wrapper verification was invalid**:
after `cp` of the merged lib over `wrapper/build/libvtk_julia.so`, the
CMake fallback build reported "Built target" **without relinking** (the
copied lib was newer than its objects), so the following suite ran against
the *merged* lib again and misleadingly printed 97/97. I was about to force
`cmake --build wrapper/build --clean-first` and re-run the hand-wrapper
suite when told to stop. **No commands were run after that realization.**

## What needs to be done (in order)

1. **Re-verify the hand-written fallback properly** (CMake caches its link
   output, so force it):
   ```sh
   cd ~/vtk.jl/VTK
   cmake --build wrapper/build --clean-first -j $(nproc)
   rm -rf ~/.julia/compiled/v1.12/VTK
   julia --project=test test/runtests.jl
   # expect 91/91 and the line "auto-shim not present (hand-written wrapper) — skipping"
   ```
2. **Restore the default library to the merged one** (the clean-first build
   leaves the hand-written lib at the default path):
   ```sh
   cp gen/wrapit/build/shipped/libvtk_julia.so wrapper/build/libvtk_julia.so
   ```
3. **Watch CI on this push** (`CI` + `Documentation` workflows): first run
   with the new `apt-get install libclang-dev clang libssl-dev` steps and
   the from-source wrapit build. Possible surprises: different libclang
   version on ubuntu-latest than local 22 (the code was only validated with
   clang 13 jll + 22 system), CMake `CLANG_PREFIX` auto-detection, network
   access for the wrapit clone and its `FetchContent` of cxxopts.
4. **Docs deploy**: new pages `docs/wrapit-upstream-bugs.md` and
   `docs/patches/` land with the deploy; `docs/make.jl` itself is unchanged
   since the CSS fix (which is live and confirmed working).
5. Optional follow-ups, in value order:
   - Submit the Bug-1 patch **upstream to `grasph/wrapit`** (it is currently
     only merged in our fork). `docs/wrapit-upstream-bugs.md` has the
     issue-ready text; patch in `docs/patches/wrapit-bug1-null-cstring.patch`.
   - Bug 3 (Julia keywords exported): easy PR, a few lines in the export
     writer (`CodeTree.cpp` `to_export_` loop); could go on the same fork.
   - Bug 2 (`inheritances` override for template parents): ~15 lines in
     `getParentClassesForWrapper`; would delete the AOS post-processor.
   - Bug 4 (ostream wrapped uncompilable): needs a policy decision; our
     ostream vetoes in `veto.txt` are load-bearing until then.
   - `gen/wrapit/build.jl`'s latest edit was a **comment-only** clarification
     of the clash-veto rule; no rebuild needed for it.

## Notes for the next session

- A/B testing discipline: `rm -rf ~/.julia/compiled/v1.12/VTK` whenever
  switching libraries; the precompile cache does not track `VTKJL_LIB`.
- Test counts: 97/97 on the merged lib (6 auto-shim tests), 91/91 on the
  hand-written fallback (auto-shim testset skips).
- No Kaimon session is running (I shut both down). All scratch work is in
  `/tmp/opencode/` (wrapit upstream clone + patched build + bug-1 A/B
  repro) and can be discarded; the wrapit clone used by the driver lives in
  `gen/wrapit/build/wrapit-src` (gitignored).
