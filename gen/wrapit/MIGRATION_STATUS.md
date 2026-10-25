# WrapIt migration — status & handover (2026-10-25)

**One-line state: the WrapIt-generated + shim-merged library passes the full
91-test suite as a drop-in replacement for the hand-written wrapper (A/B via
`VTKJL_LIB`). The migration is NOT flipped yet — the shipped default still
loads `wrapper/build/libvtk_julia.so` (CMake/hand build).**

## How to reproduce the current green state

```sh
julia --project=gen/wrapit -e 'using Pkg; Pkg.instantiate()'   # once
julia --project=gen/wrapit gen/wrapit/build.jl                 # generate+merge+compile (~2 min)
rm -rf ~/.julia/compiled/v1.12/VTK                              # kill stale cache!
VTKJL_LIB=$PWD/gen/wrapit/build/shipped/libvtk_julia.so \
  julia --project=test test/runtests.jl                         # expect 91/91
```

**CRITICAL GOTCHA (cost a debugging session):** Julia's precompile cache does
not track `ENV["VTKJL_LIB"]`. After building, ALWAYS
`rm -rf ~/.julia/compiled/v1.12/VTK` before an A/B run, or you silently test
the previously-cached library (this masked failures for several iterations).

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
   conveniences — and now also `upcast_dataarray` (see below).

## Hard-won findings (read before touching anything)

1. **Regex vetoes in WrapIt do NOT work** (at least 1.8.0). All successful
   vetoes are exact signature matches. The ostream/PrintSelf removals in the
   original spike were auto-veto (undefined type), not regex effect.
   `veto.txt` now contains some dead regex lines (harmless; `/std::basic_ostream.*/`
   line 1, `/.*/ostream.*/` removed already — audit when convenient).
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
   router in `src/typedarray.jl`. `force_sp_instantiation` (calling jlcxx
   internals directly) was tried and DID NOT work — reverted.
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

## TODO (tomorrow, in order)

1. **Stability**: confirm the 6-run background loop result (expected 0/6);
   then flip CI to exercise BOTH libs (matrix env var) or at least the merged
   one.
2. **Conformance**: `gen/wrapit/conformance.jl` references
   `VTKGen.VTKDataArray` which does not exist (typed wrapper is Julian-layer;
   the file was mid-edit when paused — it likely errors). Rewrite it to load
   the merged lib directly (`@wrapmodule` like `src/VTK.jl` does, no
   VTKGen.jl package) and run the oracle; or simplest: make it a thin wrapper
   that runs the main suite against the merged lib.
3. **THE FLIP**: make the driver the default build path:
   - `gen/build_wrapper.jl` → thin wrapper calling `gen/wrapit/build.jl`,
     then `cp gen/wrapit/build/shipped/libvtk_julia.so wrapper/build/`.
   - CI + docs workflows: add `julia --project=gen/wrapit -e 'using Pkg;
     Pkg.instantiate()'` before the wrapper build step.
   - Keep CMake/`wrapper/` as fallback until the generated lib proves itself
     in CI; document `VTKJL_LIB` as the escape hatch.
   - Decide fate of `wrapper/src/vtk_julia.cpp`: it is now the *source* from
     which `shim_vtkjl.cpp` was extracted; keep as reference or retire.
4. **Docs deployment CSS bug (user-reported)**: https://ffrancesco94.github.io/VTK.jl/
   renders unstyled. Hypotheses, cheapest first:
   - VitePress `base` mismatch: for project pages it must be `/VTK.jl/`;
     check `gen/wrapit/build/jl/.vitepress/config.*` or the generated
     `docs/build/.documenter/.vitepress/config.mts` `base` field vs the
     actual served path. Locally the site renders fine, which points at
     base/deploy_url rather than missing assets.
   - `MarkdownVitepress(deploy_url = "ffrancesco94.github.io/VTK.jl")` in
     docs/make.jl — verify DocumenterVitepress derived the right base.
   - Check gh-pages content: does `dev/index.html` reference
     `/assets/...` (wrong, implies base `/`) vs `/VTK.jl/assets/...`?
   - The multi-base build dirs (`build/1` + `bases.txt`) and how deploydocs
     maps them — possibly the site root vs `dev/` mismatch.
5. **Cleanup**: dead regex veto lines in veto.txt; `__debug_sp_state`
   removed already? (verify); stale `build/jl/deps/libjlVTKGen.so` copy
   mechanism in build.jl (still needed for VTKGen.jl — see TODO 2).
6. Update `STATUS.md` (WrapIt item → migration in progress → done after flip),
   `gen/wrapit/README.md` (single merged lib architecture), and the docs
   implementation page (wrapit.md) when the flip lands.

## Files touched by the migration (uncommitted at pause)

- `gen/wrapit/build.jl` — clash/type audits, steering postprocess, merged
  compile, veto-loop persistence fix.
- `gen/wrapit/shim_vtkjl.{h,cpp}` — NEW merged shim (extracted from hand
  wrapper + upcast_dataarray).
- `gen/wrapit/shim.cpp` — DELETED (superseded).
- `gen/wrapit/veto.txt` — +~90 entries (new classes' macro methods, clash
  vetoes, ostream exact vetoes).
- `gen/wrapit/wrapit.toml.template` — +vtkXMLPolyDataReader, vtkObjectBase,
  vtkImageData, vtkDataSetAlgorithm, c2p/p2c/surface headers.
- `gen/wrapit/conformance.jl` — mid-rewrite (see TODO 2; currently broken).
- `src/typedarray.jl` — `_as_dataarray_sp` routing + SP alias (works, 91/91).

## Known-good references

- Hand wrapper still builds/pass: default path `julia --project=.` +
  `gen/build_wrapper.jl` (CMake) → suite passes 91/91 (verified this session).
- Merged lib: `gen/wrapit/build/shipped/libvtk_julia.so` → 91/91.
