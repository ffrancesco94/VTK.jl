# Capability matrix

This page tracks VTK.jl's current feature coverage at four different layers.
It is a manually maintained snapshot of the repository on **2026-11-25**, not
a claim of PyVista feature parity.

| Symbol | Meaning |
|---|---|
| ✅ | Present for the currently advertised scope |
| ◐ | Partial, indirect, experimental, or with important caveats |
| — | Absent, or no dedicated coverage |
| N/A | Not applicable to this layer |

The columns have deliberately strict meanings:

- **Raw binding**: the required classes/methods are registered in the current
  WrapIt-generated + shim `libvtk_julia`. A class merely being present in
  `VTK_jll` does not count.
- **High-level API**: a supported Julian convenience in `src/*.jl`. Calling a
  generated VTK method or using `_cp` does not count as high-level coverage.
- **Tested**: direct automated behavioral coverage in `test/`. Class
  registration and indirect use alone do not count; ◐ indicates smoke,
  indirect, or incomplete option/type coverage.
- **Documented**: a user-facing tutorial or public API documentation. A
  roadmap entry or an implementation-only note does not count as full user
  documentation.

The matrix should be updated in the same change as the corresponding binding,
Julian API, tests, or documentation. The authoritative sources are
`gen/wrapit/VTK.wit.in` and the generated/shim sources for raw coverage,
`src/*.jl` for high-level coverage, `test/*.jl` for tests, and `docs/src` for
documentation. The follow-up plan is in
[`STATUS.md`](https://github.com/ffrancesco94/VTK.jl/blob/main/STATUS.md#7-recommended-sequence--toward-a-julian-pyvista).

## Data model and arrays

| Capability | Raw binding | High-level API | Tested | Documented | Current scope / next gap |
|---|:---:|:---:|:---:|:---:|---|
| Numeric array factories and scalar-type discovery | ✅ | ✅ | ✅ | ✅ | `vtkDataArray` plus concrete numeric factories; `data_array(T, ncomp)` and `VTKDataArray{T}` cover VTK's numeric scalar types. |
| VTK-memory → Julia zero-copy AOS views | ✅ | ✅ | ✅ | ✅ | `data`, `raw_data`, typed indexing, and GC-retention tests. Wrappers resynchronize after aliased/raw structural changes; old derived views still dangle after reallocation and growth is uninitialized. |
| Existing Julia-buffer → VTK zero-copy adoption | — | — | — | — | Current zero-copy path is in the VTK-to-Julia direction. Define ownership before adding the reverse direction. |
| SOA/variant storage and string arrays | ◐ | — | — | ◐ | The abstract array API exists, but typed views are numeric host-side AOS only; concrete `vtkStringArray`/`vtkVariantArray` support is not wrapped. |
| Unstructured-grid construction from Julia data | ✅ | ✅ | ✅ | ✅ | `UnstructuredGrid(points, cells)` validates sizes, fixed/variable cell arity, and point bounds. It still inserts point-by-point and converts through `Float64`; a bulk path remains open. |
| PolyData topology construction | ✅ | — | ◐ | — | Raw factory and verts/lines/polys/strips methods exist. Tests only exercise an empty `PolyData_new()`; no Julia-data topology constructor exists. |
| ImageData construction and metadata | ✅ | — | — | — | Raw factory and dimensions/origin/spacing methods exist; no ergonomic constructor or structured-array interface. |
| RectilinearGrid construction | ✅ | — | — | — | Raw factory and x/y/z coordinate-array setters exist; no `RectilinearGrid(x, y, z)` convenience. |
| StructuredGrid construction | ✅ | — | — | — | Raw factory, points, and dimensions APIs exist; no coordinates-plus-dimensions constructor. |
| Cell/point iterators and VTKBase `MeshCell` conversion | ✅ | ✅ | ✅ | ✅ | `cell(s)`, `eachcell`, `eachpoint`, `coordinates`, and WriteVTK-compatible connectivity. High-order/polyhedral conveniences remain limited. |
| Bounds, center, dimensions, extent, origin, spacing, ranges | ✅ | — | ◐ | — | Many raw getters exist. Current high-level coverage is mainly `npoints`/`ncells`; structured metadata is checked indirectly through I/O. |
| Point/cell/general field data and active attributes | ✅ | ◐ | ◐ | ◐ | High-level point/cell arrays and active scalars exist. Nonnumeric arrays fail deliberately in numeric accessors. General field data, active vectors/tensors/normals/texture coordinates, nonnumeric values, and dictionary-like access are missing. |
| Downcast, null handling, and shallow/deep copy | ✅ | ◐ | ✅ | ✅ | Hierarchy-aware downcast covers six registered types, returns an owning generic fallback, and reports null/invalid forced downcasts deliberately. Deep-copy snapshots are exposed mainly through temporal readers. |
| Tabular data (`vtkTable`) | — | — | — | — | Wrap `vtkTable`/`vtkTableAlgorithm` and necessary abstract-array support for native tabular datasets, Tables.jl integration, probe results, and charts. VTK 9.7 has no `vtkTableData` class. |

## Readers, writers, and file formats

| Capability | Raw binding | High-level API | Tested | Documented | Current scope / next gap |
|---|:---:|:---:|:---:|:---:|---|
| XML unstructured grid (`.vtu`) | ✅ | ✅ | ✅ | ✅ | Round trips, WriteVTK/ReadVTK interoperability, compressed output, and raw-appended output. |
| XML PolyData (`.vtp`) | ✅ | ✅ | — | ✅ | `read_vtp`/`write_vtp` exist but lack a dedicated XML round-trip/oracle test. |
| XML image/rectilinear/structured grids (`.vti/.vtr/.vts`) | ✅ | ✅ | ✅ | ✅ | Read and VTK round trips are tested. Independent write-side assertions are uneven, especially for `.vtr`/`.vts`. |
| XML multiblock (`.vtm`) | ✅ | ✅ | ✅ | ✅ | Numeric flat access plus manual nested descent; named/recursive composite abstractions are missing. |
| Legacy VTK (`.vtk`) | ✅ | ✅ | ◐ | ✅ | Generic reader/writer tested with unstructured grids only; high-level output is ASCII and other dataset types need coverage. |
| EnSight Gold and CGNS readers | ✅ | ✅ | ✅ | ✅ | Steady and transient reads, out-of-order steps, and time lookup. Snapshot/option coverage is not identical for both formats. |
| EnSight/CGNS writers | — | — | — | — | Reader-only at present. |
| Parallel PolyData summary (`.pvtp`) | ✅ | ✅ | ✅ | ✅ | Serial reader merges pieces into one `PolyData`; this is not distributed execution. |
| Other parallel XML and `.pvd` collections | — | — | — | — | Add `.pvtu`/`.pvti`/`.pvtr`/`.pvts`, parallel writers, and general time-series collections. |
| Generic extension-dispatching read/save | N/A | — | — | — | Users must choose `read_vtu`, `read_cgns`, etc. Add a common frontend and extensible reader/writer registry. |
| Uniform encoding/compression/binary controls | ✅ | ◐ | ◐ | ◐ | Raw XML and legacy controls exist. Only `write_vtu` exposes `raw_appended`; other XML writers hard-code compression and legacy writing lacks a binary keyword. |
| STL/PLY/OBJ, XDMF/VTKHDF, OpenFOAM/Exodus/Fluent/Gmsh | — | — | — | — | Prioritize by workflow demand after the common I/O frontend exists. |

## Filters, sources, and pipelines

| Capability | Raw binding | High-level API | Tested | Documented | Current scope / next gap |
|---|:---:|:---:|:---:|:---:|---|
| Implicit plane, clip, and slice | ✅ | ✅ | ✅ | ✅ | Analytic unit-hex checks exist. Clip deliberately returns `vtkUnstructuredGrid` for every input type. |
| Contour and external-surface extraction | ✅ | ◐ | ✅ | ✅ | Basic analytic paths work. Contour selects arrays without changing input active scalars; only part of the raw configuration is exposed. |
| Cell ↔ point conversion | ✅ | ✅ | ◐ | ✅ | Constant/linear analytic checks exist; `arrays=`, pass-data, and input-type combinations need broader tests. |
| Calculator, gradient, and threshold | ✅ | ◐ | ✅ | ✅ | Mainly point-scalar subsets are exposed. Gradient preserves the input dataset type and threshold does not mutate active attributes; broader raw options remain open. |
| Static stream tracing | ✅ | ◐ | ✅ | ✅ | A constant-vector streamline is tested. Directions are validated and vector selection does not mutate input state; broader integration controls and seed variants remain open. |
| Particle/path tracing | ✅ | ◐ | — | ◐ | Quarantined under `VTK.Experimental.particle_tracer`: a static-grid execution crashed and there is no validated execution example. |
| Line source and line probing | ✅ | ◐ | ✅ | ✅ | Line generation works. Probe tests include numerical values, input nonmutation, and `scalars` allowlists with validity-mask preservation. |
| Persistent/lazy pipelines, connections, and ports | ✅ | — | ◐ | ◐ | Raw input connections, output ports, time updates, progress, and cancellation exist. High-level filters eagerly execute and return only output port zero. |
| General geometry sources beyond lines | — | — | — | — | Add sphere, box/cube, plane, cylinder, cone, arrow, point-cloud, and structured sources. |
| Transforms, connectivity, extraction, cleanup, and merging | — | — | — | — | Add translate/rotate/scale/reflect, feature edges, connected regions, point/cell subsets, clean/merge, append, and triangulation. |
| Surface processing and analysis | — | — | — | — | Add normals, smoothing, decimation, subdivision, shrink, extrusion, tube/glyph, cell sizes/quality, integration, and warp. |

## Composite and temporal data

| Capability | Raw binding | High-level API | Tested | Documented | Current scope / next gap |
|---|:---:|:---:|:---:|:---:|---|
| Flat multiblock construction and numeric indexing | ✅ | ✅ | ✅ | ✅ | `MultiBlockDataSet(n)`, `nblocks`, `block`, and `set_block!` have validated indices and tested reference-counted parent/child lifetime contracts. |
| Named blocks and recursive composite traversal | ◐ | — | ◐ | ◐ | Raw metadata primitives exist; tests manually descend nested blocks. Add names, paths, leaf iteration, and recursive filter/plot behavior. |
| EnSight/CGNS temporal reader interface | ✅ | ✅ | ✅ | ✅ | `timesteps`, `read_timestep`, `read_at`, and `eachstep` return detached snapshots by default, retain filename context, isolate timestep metadata, and test collected-step retention; `copy=false` explicitly selects borrowed pipeline contents. |
| General temporal readers/writers and temporal filters | — | — | — | — | Generalize beyond EnSight/CGNS to XML/PVD/file series and reusable temporal pipelines. |
| Partitioned datasets, DataAssembly, and AMR collections | — | — | — | — | Later modern-composite data-model work. |

## Plotting, interoperability, and execution

| Capability | Raw binding | High-level API | Tested | Documented | Current scope / next gap |
|---|:---:|:---:|:---:|:---:|---|
| Native Julia plotting with Makie | N/A | — | — | — | Preferred plotting direction. Start with GeometryBasics conversion and optional Makie recipes; add static/interactive backends and off-screen tests. |
| Native VTK rendering bindings | — | — | — | — | No renderer/window/actor/mapper/camera classes are wrapped. Deferred while Makie is the preferred path; reconsider only for capabilities Makie cannot provide. |
| GeometryBasics conversion | N/A | — | — | — | Practical first interoperability target for Makie: points, lines, faces, and field arrays. Define copy/ownership and mixed-cell/tessellation rules. |
| Meshes.jl conversion | N/A | — | — | — | Complementary to GeometryBasics, not a strict Makie prerequisite. Requires a target representation for mixed-cell grids. |
| Tables.jl and tabular results | N/A | — | — | — | Field/probe arrays can get a Tables.jl adapter early; native VTK table round trips also require `vtkTable` wrapping. |
| ReadVTK/WriteVTK interoperability | N/A | ✅ | ✅ | ✅ | VTKBase cells and coordinate arrays support direct WriteVTK use; independent file oracles run in both directions where formats permit. |
| Scoped, severity-aware diagnostics | ✅ | ✅ | ✅ | ✅ | Per-operation observers collect severity and algorithm/file context. Warnings are nonfatal, actual failures throw `VTKError`, raw calls remain unchecked, and stale/concurrent/writer/null-output paths are tested. |
| MPI-aware distributed pipelines | — | — | — | ◐ | MPI libraries are preloaded for `VTK_jll`, but controllers, rank-aware pipelines, ghost exchange, and multi-rank tests are not exposed. |
