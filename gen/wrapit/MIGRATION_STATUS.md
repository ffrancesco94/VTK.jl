# WrapIt migration — status & handover (2026-10-26)

**One-line state: FLIPPED. The WrapIt-generated + shim-merged library built by
`gen/build_wrapper.jl` is the shipped default (`wrapper/build/libvtk_julia.so`).
The hand-written CMake wrapper (`gen/build_wrapper_cmake.jl`, `wrapper/`) is
the fallback; CI exercises both (matrix `wrapper: [generated, hand]`, A/B via
`VTKJL_LIB`). Full suite: 91/91 on both libraries (verified 2026-10-26).**

## Post-flip state (2026-10-26)

- `gen/build_wrapper.jl` — thin entry point: instantiates the driver env, runs
  `gen/wrapit/build.jl`, installs the merged library into `wrapper/build/`.
- `gen/build_wrapper_cmake.jl` — the legacy CMake build, same output path
  (so it stays a drop-in fallback).
- CI (`.github/workflows/CI.yml`): matrix `version × wrapper`; `VTKJL_LIB` is
  pinned at job level **before** `julia-buildpkg` because `@wrapmodule`
  dlopens the library at module-definition (precompile) time. The C++ build
  step runs before `julia-buildpkg` for the same reason.
- `conformance.jl`: rewritten to load the merged library directly via
  `@wrapmodule` in a scratch module (no VTKGen.jl package, no `LOAD_PATH`
  tricks); uses the shim's owning `*_new` factories and the Julian layer's
  `_cp` raw-pointer pattern. The stale `build/jl/deps/libjlVTKGen.so` copy was
  removed from `build.jl`.
- `wrapper/src/vtk_julia.cpp`: back-ported the three `upcast_dataarray`
  overloads (the Julian layer's `_as_dataarray_sp` requires them; their
  absence made CI red on main).
- Docs deployment CSS bug: **fixed** — root cause was
  `deploy_url = "ffrancesco94.github.io/VTK.jl"` (no scheme) in `docs/make.jl`;
  DocumenterVitepress only strips the domain when the scheme is present, so
  the VitePress base became `/ffrancesco94.github.io/VTK.jl/dev/` and every
  asset 404'd. Now `https://ffrancesco94.github.io/VTK.jl`. Also fixed the
  doubled `https://https://` in "Edit this page" links by passing
  `repo = "github.com/..."` (DocumenterVitepress prepends the scheme itself).
- Cleanup: the dead-regex-veto-line cleanup was attempted and **reverted**
  (see finding 1 — the regex lines veto ostream wrappers and are required);
  `__debug_sp_state` was already gone.

## How to reproduce the current green state

```sh
julia --project=. gen/build_wrapper.jl            # default (WrapIt) build + install
julia --project=. gen/build_wrapper_cmake.jl      # fallback (CMake/hand) build
rm -rf ~/.julia/compiled/v1.12/VTK                # kill stale cache!
julia --project=test test/runtests.jl             # 91/91 (default path)
VTKJL_LIB=$PWD/gen/wrapit/build/shipped/libvtk_julia.so \
  julia --project=test test/runtests.jl           # 91/91 (explicit merged lib)
julia --project=gen/wrapit gen/wrapit/conformance.jl  # analytic-oracle gate
```

**CRITICAL GOTCHA (cost a debugging session):** Julia's precompile cache does
not track `ENV["VTKJL_LIB"]`. After building, ALWAYS
`rm -rf ~/.julia/compiled/v1.12/VTK` before an A/B run, or you silently test
the previously-cached library (this masked failures for several iterations).
Also: never precompile the VTK package in one environment and run tests with
a different `VTKJL_LIB` — bake the env var into the whole job/session.

## Architecture of the merged library (what build.jl produces)

Single shared library `gen/wrapit/build/shipped/libvtk_julia.so`, one
`JLCXX_MODULE`:

1. **WrapIt-generated code** (`cxx/JlClasses.cxx` + `cxx/jlVTKGen.cxx`
   steering): ~60 classes, 1200+ methods, types with true VTK inheritance.
2. **Post-processing** (in `build.jl:postprocess!`, Julia):
   - AOS leaf arrays re-based onto `vtkDataArray` + `SuperType` (WrapIt bug 2).
   - WrapIt's parametric `vtkSmartPointer` wrapper stripped (3 regex blocks +
     steering refs); real smart-pointer support comes from the shim.
   - `#include "shim_vtkjl.h"` injected into **both** TUs (smart-pointer
     traits must be visible per translation unit — `ToAOSDataArray` in the
     generated TU returns `vtkSmartPointer<vtkDataArray>`).
   - `register_shim_methods(jlModule)` injected into the steering file before
     the per-class `add_methods()` loop.
3. **Hand shim** (`shim_vtkjl.h` / `shim_vtkjl.cpp`, ~510 lines, extracted
   mechanically from `wrapper/src/vtk_julia.cpp`): smart-pointer traits +
   `add_smart_pointer`, `take_ref`, error window (`install_error_window` /
   `vtk_last_error`), zero-copy workers (`zero_copy_data`/`zero_copy_matrix`),
   all `*_new` factories (owning), take_ref'd getters (`GetOutput`,
   `GetPoints`, `GetPointData`, `GetCellData`), `SetInputData` per-filter,
   `SetFileName`/`SetInsideOut`/`SetArrayName`/... macro accessors, downcasts,
   `CreateDataArray`, `HasArray`, `GetArrayNameOf`, `InsertNextCell`
   (vector overload), `GetCellTypeId`/`GetCellPointIds`, writer compression
   conveniences — and `upcast_dataarray` (also back-ported into the hand
   wrapper, which is now the shim's twin).

## Hard-won findings (read before touching anything)

1. **Regex veto lines in veto.txt are load-bearing — do not "clean them up".**
   Removing `/std::basic_ostream.*/` (and the other regex lines) makes
   generation emit ostream-related wrappers (74 classes / 1442 methods
   instead of 72 / 1397, "Failed to find type declaration of ostream"),
   which then breaks the build (WrapIt bug 4 territory). The earlier belief
   that "regex vetoes do not work" was wrong: at least these patterns match.
   The exact-signature duplicates of `/::GetOutput()/`, `GetPointData()` etc.
   were kept anyway — they document the clashing signatures explicitly.
2. **vtkObjectBase.h must stay in input** — but it includes `<iostream>`,
   which *defines* `std::ostream`, which DISABLES the auto-veto of
   ostream-methods. Exact vetoes for `vtkObjectBase::Print/PrintHeader/
   PrintTrailer` are in veto.txt. Removing vtkObjectBase.h would re-break
   shim type registration (it needs vtkObjectBase registered).
3. **CxxWrap smart-pointer casts**: AOS leaf smart-pointer types reach module
   load pre-registered *without* `__cxxwrap_smartptr_cast_to_base`; the lazy
   factory path is skipped. Fix shipped: explicit C++-side
   `upcast_dataarray(const vtkSmartPointer{Double,Float,Int}&) →
   vtkSmartPointer<vtkDataArray>` shim methods + Julia `_as_dataarray_sp`
   router in `src/typedarray.jl` (present in BOTH the merged shim and the
   hand wrapper). `force_sp_instantiation` (calling jlcxx internals
   directly) was tried and DID NOT work — reverted.
4. **Ambiguities to veto** (both shim & generated define near-identical
   methods): exact-signature vetoes in veto.txt for `GetOutput()`,
   `GetPointData()`, `GetCellData()`, `vtkPointSet::GetPoints()`,
   `vtkFieldData::GetArray(const char *)`, `vtkFieldData::HasArray(const char *)`,
   `vtkDataSetAttributes::SetActiveScalars(const char *)`,
   `vtkAlgorithm::Update()`, plus the mechanical clash list.
5. **`veto_shim_clashes!()` in build.jl** re-derives clash vetoes on every
   build (compares shim signatures vs generated, handles default-arg
   truncation) — extend `input` and it self-heals.
6. **`check_shim_types_registered!()` in build.jl** audits every vtk type
   referenced by the shim against `add_type<...>` emissions — this caught
   the missing `vtkXMLPolyDataReader`, `vtkCellDataToPointData`,
   `vtkPointDataToCellData`, `vtkDataSetSurfaceFilter`, `vtkImageData` (all
   now in `wrapit.toml.template`, plus `vtkDataSetAlgorithm.h`,
   `vtkObjectBase.h`).
7. **Driver bug fixed:** the veto loop must write `veto.txt` after EACH new
   veto (wrapit reads the file each run), not at the end.
8. Duplicate Julia methods (even identical) are **fatal during
   precompilation** ("Method overwriting is not permitted") — hence the
   clash vetoes must be complete.
9. **Precompile-time dlopen**: `@wrapmodule` dlopens at module definition,
   i.e. during `Pkg.precompile` too. CI must build the C++ wrapper before
   `julia-buildpkg` (or tolerate a non-strict precompile failure and compile
   at test time, slower and noisier).

## Files touched by the migration (all committed at flip)

- `gen/build_wrapper.jl` — now the thin WrapIt-driver entry point.
- `gen/build_wrapper_cmake.jl` — NEW: legacy CMake build (fallback).
- `gen/wrapit/build.jl` — clash/type audits, steering postprocess, merged
  compile, veto-loop persistence fix; VTKGen-package `.so` copy removed.
- `gen/wrapit/shim_vtkjl.{h,cpp}` — merged shim (extracted from hand
  wrapper + upcast_dataarray).
- `gen/wrapit/conformance.jl` — direct `@wrapmodule` oracle gate.
- `gen/wrapit/veto.txt` — exact-signature vetoes PLUS load-bearing regex
  lines (`/std::basic_ostream.*/` and friends — see finding 1; do not remove).
- `wrapper/src/vtk_julia.cpp` — + `upcast_dataarray` (3 overloads).
- `.github/workflows/CI.yml` — `version × wrapper` matrix, job-level
  `VTKJL_LIB`, wrapper build before buildpkg.
- `.github/workflows/Documenter.yml` — instantiate the driver env, default
  build.
- `docs/make.jl` — `deploy_url` scheme fix (CSS) + `repo` scheme fix
  (edit links).
- `STATUS.md`, `README.md`, `gen/wrapit/README.md`,
  `docs/src/implementation/wrapit.md`, `docs/src/getting_started.md` —
  updated for the flipped default.

## Known-good references

- Default build (`gen/build_wrapper.jl`, WrapIt-merged): suite 91/91,
  conformance PASSED (2026-10-26).
- Fallback build (`gen/build_wrapper_cmake.jl`, hand-written): suite 91/91
  (2026-10-26).

## Not done / next

- Retire `wrapper/` entirely once the generated lib proves itself over a
  few weeks of CI (keep `VTKJL_LIB` as the documented escape hatch).
- WrapIt upstream bug reports (4 candidates, repros in `docs/wrapit-spike.md`).
- Remaining roadmap items are unchanged (more I/O formats/filters, generic
  `downcast`, jll packaging — see `STATUS.md` §6).
