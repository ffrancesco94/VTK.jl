# VTK.jl — Status & Implementation Plan

Last updated: 2026-10-23 (typed array wrapper landed; 61 tests passing on `main`).

## 1. Goal

Julia bindings for a CFD-oriented subset of VTK 9.7: data model, XML I/O, and
manipulation filters (clip, slice, cell↔point conversion, contour, surface
extraction). No rendering, no MPI-aware API. Long-term: a maintainable
binding-generation pipeline (WrapIt or a `vtkWrapJulia` back-end) and an
idiomatic "Julian" layer on top of the raw bindings.

## 2. Current state (what works)

Binary/runtime foundations:

- `VTK_jll` 9.7.1 provides full headers, `lib/cmake/vtk-9.7` configs, and the
  `vtkWrap*` tools; we build our binding module against it with CMake
  (`gen/build_wrapper.jl`). No local VTK build needed.
- MPI: VTK_jll is an MPI-enabled build; `libmpi` (MPICH/OpenMPI/MPIABI flavor)
  is pre-loaded in `VTK.jl` before the wrapper library is dlopened.
- Ownership: all factories/outputs return `vtkSmartPointer{T}` registered via
  CxxWrap's custom smart-pointer traits (`IsSmartPointerType`,
  `ConstructorPointerType`). Julia finalizers drive `UnRegister`; GC-stress
  tests pass.

Wrapped surface (hand-written in `wrapper/src/vtk_julia.cpp`):

- `vtkDataArray` family: abstract API (components, tuples, names, resize),
  factories for Float32/Float64/Int32, **zero-copy views** via
  `vtkArrayDispatch` → `GetVoidPointer` → `jl_ptr_to_array` (AOS-only,
  mirroring VTK's own buffer-protocol caveat).
- Data model: `vtkPoints`, `vtkUnstructuredGrid`, `vtkPolyData`,
  `vtkImageData` (types registered; construction currently exposed for
  unstructured grids), field data (`vtkPointData`/`vtkCellData`) with
  `AddArray`/`GetArray`/`SetActiveScalars`.
- I/O: `vtkXML{UnstructuredGrid,PolyData}{Reader,Writer}`; writers emit
  zlib-compressed appended data by default, or raw appended data
  (`raw_appended=true`) which ReadVTK.jl can parse.
- Filters: `vtkTableBasedClipDataSet`, `vtkCutter`, `vtkCellDataToPointData`,
  `vtkPointDataToCellData`, `vtkContourFilter`, `vtkDataSetSurfaceFilter`,
  plus `vtkPlane` implicit function.
- Type hierarchy mirrors VTK inheritance (`vtkUnstructuredGrid <: vtkPointSet
  <: vtkDataSet <: vtkDataObject`) enabling Julia-side up-cast conversions of
  smart pointers and `SafeDownCast`-based downcasts (`UnstructuredGrid(obj)`,
  `PolyData(obj)`, `ImageData(obj)`).
- Error handling: VTK's output window is redirected into a buffer;
  `update!` throws on any VTK error (used by all high-level calls).

Julian layer (`src/dataarray.jl`, `src/dataset.jl`, `src/filters.jl`):

- `data(da)`/`raw_data(da)`: zero-copy `(ncomp, ntuples)` / flat views.
- Grid construction: `Points()`, `UnstructuredGrid()`, `pts[i] = (x,y,z)`,
  `insert_cell!`, `set_points!`, `allocate!`.
- `read_vtu`/`read_vtp`/`write_vtu`/`write_vtp`, `field_array`, `point_data`,
  `cell_data`, `activate_point_data!`.
- `plane`, `clip`, `slice`, `cell_to_point`, `point_to_cell`, `contour`,
  `extract_surface`, `update!`.

## 3. Test suite (61 tests, all passing)

- **Array core**: typed creation, zero-copy write-through both directions,
  multi-component reshape, names, Int32 element type, GC churn with
  survivors.
- **Analytic oracles**: clip of unit hex against plane x+y+z=1 (inside-out)
  yields exactly the tetrahedron (1 cell, 4 points, max coordinate sum 1.0);
  default clip side verified as complement; constant-field c2p stays
  constant; linear-field p2c averages to 1.5 on a unit hex; slice at x=0.5
  gives the unit square; contour points lie on the isosurface; surface
  extraction preserves the 8 vertices.
- **Independent oracles**: our `.vtu` output verified with ReadVTK.jl (pure
  Julia); our reader verifies WriteVTK.jl output — both directions.
- **Robustness**: GC/finalizer stress across full pipelines; missing field
  names return `nothing`.

## 4. Known limitations / design debt

1. **Array interface**: `VTKDataArray{T}` exists and is the preferred API
   (it owns the underlying smart pointer), but the untyped `data()`/`raw_data()`
   still return unguarded raw views for smart-pointer inputs.
2. **Argument-passing pattern**: C++ methods take raw `T*` and the Julian
   layer converts via `_cp(T, obj)` (`CxxPtr{T}(obj[])`). CxxWrap's by-value
   smart-pointer argument path is unusable for custom smart pointers
   (`Type{Dereferenced{T}}` dispatch is impossible — Julia's `Type` is
   invariant). Any future generator must emit this pattern or register
   `const T&` overloads.
3. **Arrays**: only Float32/Float64/Int32 factories; no typed get/set
   accessors (all access goes through zero-copy views or the slow
   double-based virtual API); SOA/variant arrays unsupported for zero-copy
   (guarded, throws).
4. **I/O**: XML only (`.vtu/.vtp`); `.vti/.vtr/.vts`, legacy `.vtk`,
   multiblock `.vtm`, parallel readers are unwrapped. Writer only emits
   appended data (fine for CFD).
5. **Data model**: unstructured grids fully constructible from Julia; other
   grid types readable but not constructible. Cell types are bare integers
   (`VTK_HEXAHEDRON = 12`).
6. **Downcasts**: hand-written per type (`UnstructuredGrid(obj)` etc.); no
   generic `downcast` based on class name.
7. **Distribution**: wrapper builds locally via system CMake; no
   `VTK_julia_jll` BinaryBuilder recipe yet — every user needs a C++17
   toolchain.
8. **vtkWrapJulia / WrapIt**: automation spike deferred; the hand-written
   layer is the conformance spec.

## 5. Risks

- WrapIt may hit the same smart-pointer argument issues; mitigated by the
  `_cp` pattern and `const T&` overload fallback.
- VTK_jll has no Windows build; Windows support requires our own VTK build.
- VTK_jll's MPI flavor complicates end-user installs; escape hatch is a
  custom non-MPI VTK build (defer until requested).

## 6. Roadmap

### Phase 1 completion (this sprint)

- [x] `SetActiveScalars` plumbing for `contour` (`scalars=` kwarg)
- [x] ReadVTK-compatible raw-appended writer mode
- [x] **`VTKDataArray{T}` parametric wrapper** (decided design):
      `AbstractMatrix{T}` of shape `(ncomp, ntuples)` holding the smart
      pointer (ownership), zero-copy cached view, typed `getindex`/`setindex!`,
      `resize!`; `field_array`/`points_array` return typed wrappers; generic
      typed factory `data_array(T, ncomp)` via `vtkAbstractArray::CreateArray`
- [x] `HasArray` C++ helper; `field_array` returns typed wrapper or `nothing`

### Phase 2 — breadth + automation

- [ ] WrapIt spike on the conformance subset (must reproduce §2's surface);
      decide WrapIt vs hand-rolled `vtkWrapJulia` emitting CxxWrap code
- [ ] More readers/writers: `.vti/.vtr/.vts`, legacy `.vtk`, multiblock
- [ ] More filters: calculator, gradient, threshold, stream tracer (as CFD
      needs arise)
- [ ] Generic name-based `downcast`
- [ ] Cell type registry ( names → VTK ids, matching VTKBase.jl vocabulary )

### Phase 3 — Julian layer

- [ ] Cell/point iterators, `UnstructuredGrid` ⇄ WriteVTK/VTKBase converters,
      Meshes.jl/GeometryBasics bridges
- [ ] Memory-management hardening: views that own parent references
- [ ] Performance pass: typed accessors via `vtkArrayDispatch` if profiling
      demands it

### Phase 4 — packaging

- [ ] `VTK_julia_jll` via BinaryBuilder (Geant4.jl pattern), CI binary cache
- [ ] Registration in General

## 7. Next sprint: detailed task list

1. Add `GetDataType`/`CreateArray`/`HasArray` to `wrapper/src/vtk_julia.cpp`
   (scalar type id discovery, generic typed factory, field-membership query).
2. Implement `src/typedarray.jl`:
   - `VTKDataArray{T} <: AbstractMatrix{T}` holding `SmartPointer{vtkDataArray}`
     + cached zero-copy `Matrix{T}` view
   - constructors from any array smart pointer (type id → Julia type);
     `data_array(::Type{T}, ncomp)` factory; VTK↔Julia type-id maps
   - `Base.size/getindex/setindex!/IndexStyle/iterate/resize!`
   - `field_array`, `points_array` return `VTKDataArray{T}`; keep
     untyped `*_raw` variants for the old behavior
3. Re-point existing tests at the typed wrapper where natural; add typed
   tests: type stability (`@inferred`), value round-trips through the typed
   API, zero-copy visibility, resize invalidation, GC stress with views.
4. Docs: README example with the typed interface; STATUS.md update.
5. Full test run; commit.
