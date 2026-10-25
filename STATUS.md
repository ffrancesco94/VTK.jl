# VTK.jl — Status & Implementation Plan

Last updated: 2026-10-24 (WrapIt spike: verdict WrapIt+shim, driver in
`gen/wrapit/`, report in `docs/wrapit-spike.md`).

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
  `vtkArrayDispatch` → `GetVoidPointer` → CxxWrap `make_julia_array`
  (AOS-only, mirroring VTK's own buffer-protocol caveat). Views are created
  directly at the target dimensionality (flat vector or `(ncomp, ntuples)`
  matrix) as plain `Array`s; `create_if_not_exists<ArrayRef<V,2>>` is needed since CxxWrap
  pre-registers only 1-D array wrapper types.
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

Julian layer (`src/dataarray.jl`, `src/typedarray.jl`, `src/dataset.jl`,
`src/cells.jl`, `src/filters.jl`):

- `data(da)`/`raw_data(da)`: zero-copy `(ncomp, ntuples)` / flat views
  derived from an **owning** `VTKDataArray` wrapper ("wrapper-owns-
  everything"): the underlying array stays alive as long as any derived
  view does, even if the original handle is dropped.
- Grid construction: `Points()`, `UnstructuredGrid()`, `pts[i] = (x,y,z)`,
  `insert_cell!` (accepts raw ids or `VTKCellTypes.VTKCellType`),
  `set_points!`, `allocate!`; `UnstructuredGrid(points, cells)` from a 3×n
  matrix + `MeshCell` vector.
- `read_vtu`/`read_vtp`/`write_vtu`/`write_vtp`, `field_array`, `point_data`,
  `cell_data`, `activate_point_data!`.
- Cell/point access: `cell_type`/`cell`/`cells`/`eachcell` (VTKBase
  `MeshCell`, 1-based connectivity), `eachpoint`, `coordinates` (zero-copy
  typed 3×n view). Cell vocabulary comes from VTKBase (`VTKCellTypes`), the
  shared registry of ReadVTK/WriteVTK — `cells(grid)` is directly consumable
  by `WriteVTK.vtk_grid`.
- `plane`, `clip`, `slice`, `cell_to_point`, `point_to_cell`, `contour`,
  `extract_surface`, `update!`.

## 3. Test suite (91 tests, all passing)

- **Array core**: typed creation, zero-copy write-through both directions,
  multi-component reshape, names, Int32 element type, GC churn with
  survivors.
- **Typed wrapper**: type-stable indexing, value round-trips through the
  typed API, zero-copy visibility, resize invalidation, type mismatches
  rejected, discovery from untyped factories.
- **Cells/iterators/converters**: VTKBase registry ids and names, 1-based
  connectivity, `eachcell`/`eachpoint`/`coordinates`, round-trip
  `UnstructuredGrid(coordinates, cells)` reconstruction, WriteVTK writes our
  mesh description and our reader reads it back.
- **Views vs GC**: views obtained via `data`/`raw_data` survive collection
  of the owner (wrapper, array, or entire grid) — dropping the last owner
  reference is safe under aggressive `GC.gc()` churn, through the untyped
  API, the typed wrapper, and grid field arrays.
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

1. **Array interface**: zero-copy views are ownership-safe — `data`/`raw_data`
   return views derived from an OWNING `VTKDataArray` wrapper (the
   "wrapper-owns-everything" design), so the owner handle may be dropped.
   Owner-capturing finalizers on views remain forbidden: an experiment
   attaching them made C++ VTK objects die on GC finalizer threads and
   reproducibly corrupted concurrently running pipelines (~25% heisenbug
   test failures; clean with `--gcthreads=1`). Remaining caveats: after
   `resize!`, previously obtained views are invalidated by VTK
   reallocation; and the grown region is NOT zero-initialized.
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
8. **vtkWrapJulia / WrapIt**: spike completed 2026-10-24 — WrapIt 1.8.0
   generates the conformance subset (63 classes / 1253 methods) with a
   driver + 10-line post-processor + 24-LOC shim; 4 upstream bugs filed as
   report candidates. Hand-written layer remains the shipped generator.

## 8. Documentation

- Tutorials (mesh building, arrays/fields, I/O, filters), implementation
  notes (architecture, ownership/GC hazard, zero-copy, WrapIt driver), and
  an autodoc API reference, built with DocumenterVitepress.jl:
  `julia --project=docs docs/make.jl` → `docs/build/1/`.
- WrapIt spike report with upstream bug repros: `docs/wrapit-spike.md`.

## 5. Risks

- CxxWrap attaches `delete` finalizers to smart pointers, so C++ VTK
  objects can die on GC finalizer threads whenever Julia collects the
  wrapper; adding *more* finalizer-driven deletions (owner-capturing view
  finalizers) empirically corrupts concurrent VTK work (see §4.1). Until the
  wrapper-owns-everything redesign, avoid patterns that defer C++ object
  death into GC.
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

- [x] WrapIt spike on the conformance subset (must reproduce §2's surface);
      decide WrapIt vs hand-rolled `vtkWrapJulia` emitting CxxWrap code
      — **done 2026-10-24: WrapIt+shim viable, `vtkWrapJulia` rejected**;
      full report `docs/wrapit-spike.md`, driver `gen/wrapit/` (experimental,
      not yet the generator for the shipped module)
- [~] WrapIt migration: the generated+shim-merged library
      (`gen/wrapit/build/shipped/libvtk_julia.so`) passes the full suite as
      a drop-in replacement (A/B via `VTKJL_LIB`), but the shipped default
      still loads the hand-written wrapper. In progress — see
      `gen/wrapit/MIGRATION_STATUS.md` for exact state and next steps.
- [ ] More readers/writers: `.vti/.vtr/.vts`, legacy `.vtk`, multiblock
- [ ] More filters: calculator, gradient, threshold, stream tracer (as CFD
      needs arise)
- [ ] Generic name-based `downcast`
- [x] Cell type registry via VTKBase (`VTKCellTypes`, a zero-dep hard dep:
      names ↔ VTK ids, singletons per id)

### Phase 3 — Julian layer

- [x] Cell/point iterators (`cell`/`cells`/`eachcell`/`eachpoint`),
      `UnstructuredGrid(points, cells)` constructor; `cells`/`coordinates`
      interop with WriteVTK (`vtk_grid(filename, coordinates, cells)`)
- [x] Memory-management hardening, "wrapper-owns-everything" design:
      `data`/`raw_data` return views derived from an owning `VTKDataArray`
      (structural lifetime, no view finalizers; §4.1/§5)
- [ ] Meshes.jl/GeometryBasics bridges — deferred (mixed-cell grids vs
      homogeneous-typed Julia meshes need a target-representation decision);
      plain `(points, cells)` data already feeds both manually
- [ ] Performance pass: typed accessors via `vtkArrayDispatch` if profiling
      demands it

### Phase 4 — packaging

- [ ] `VTK_julia_jll` via BinaryBuilder (Geant4.jl pattern), CI binary cache
- [ ] Registration in General

## 7. Next sprint: detailed task list

Completed 2026-10-24 (see git log); kept for reference. Outstanding roadmap
items, roughly in priority order:

1. WrapIt spike on the conformance subset (Phase 2) — decide WrapIt vs
   hand-rolled `vtkWrapJulia` emitting CxxWrap code.
2. More I/O: `.vti/.vtr/.vts` readers/writers, legacy `.vtk`, multiblock
   `.vtm` (Phase 2).
3. More filters: calculator, gradient, threshold, stream tracer (Phase 2).
4. Generic name-based `downcast` (Phase 2).
5. Meshes.jl/GeometryBasics bridges, once a target representation is chosen
   (Phase 3).
6. `VTK_julia_jll` BinaryBuilder recipe (Phase 4).
