# Architecture & layering

VTK.jl has three layers. Knowing where a piece lives explains most design
decisions — and most error messages.

```
┌────────────────────────────────────────────────────────┐
│ Julian layer (src/*.jl)                                 │
│   typed wrappers, iterators, do-the-right-thing helpers │
├────────────────────────────────────────────────────────┤
│ C++ binding module (wrapper/src/vtk_julia.cpp)          │
│   CxxWrap registrations: types, methods, factories      │
├────────────────────────────────────────────────────────┤
│ VTK 9.7 (VTK_jll artifacts)                             │
│   libvtkCommon*, libvtkFilters*, libvtkIOXML, ...       │
└────────────────────────────────────────────────────────┘
```

## The C++ module

A single hand-written file (`wrapper/src/vtk_julia.cpp`, ~600 lines)
registers with CxxWrap:

- **The type hierarchy** — every wrapped VTK class is registered with its
  true C++ base (`add_type<vtkUnstructuredGrid>("vtkUnstructuredGrid",
  julia_base_type<vtkPointSet>())`), so Julia subtype conversion mirrors VTK
  up-casts. Concrete AOS arrays (`vtkFloatArray`, …) really inherit a
  template in C++; they are registered under `vtkDataArray` via VTK's own
  `__VTK_WRAP__` fake-superclass trick.
- **Methods** — written as small lambdas taking *raw* `T*` pointers.
- **Factories and outputs** — return `vtkSmartPointer<T>`, registered with
  CxxWrap's custom smart-pointer traits, so Julia owns a real reference and
  finalizers release it (`UnRegister`) deterministically.

Building it is one step: `julia --project=. gen/build_wrapper.jl`
(CMake against the `VTK_jll` artifact; no local VTK build needed).

## The Julian layer

`src/*.jl` turns the raw surface into something pleasant:

| file | contents |
|---|---|
| `dataarray.jl` | untyped array helpers: `raw_data`/`data` zero-copy views, names, resize |
| `typedarray.jl` | `VTKDataArray{T}`: typed `AbstractMatrix` wrapper with cached view + scalar-type discovery |
| `dataset.jl` | grid construction, field-data access, XML I/O |
| `cells.jl` | cell registry/iterators, `MeshCell` converters, `UnstructuredGrid(points, cells)` |
| `filters.jl` | `update!`, implicit functions, the filter functions |

The package exports **nothing** on purpose: all names are used qualified
(`VTK.read_vtu`), which avoids collisions with VTKBase/WriteVTK/ReadVTK in
the same session.

## Generated smart-pointer overloads

C++ methods are registered with raw-pointer arguments. The build reads those
registrations and generates `src/generated_methods.jl`, which adds Julia
overloads accepting CxxWrap smart pointers. Each overload converts its VTK
arguments via:

```julia
_cp(::Type{T}, x) where {T} = CxxPtr{T}(x[])   # CxxPtr of static type T
```

and calls the original raw-pointer method. Generic base-class shim APIs also
get hierarchy-independent fallbacks for classes whose Julia parent chain is
incomplete. Thus ordinary code is simply `SetInputData(filter, grid)` or
`Update(reader)`, with no hand-written cast. The original methods remain
available as `Update(_cp(vtkAlgorithm, reader))` for low-level use.

Why not register by-value smart-pointer arguments? CxxWrap's by-value
smart-pointer path dispatches on `Type{Dereferenced{T}}`, and Julia's
`Type` is *invariant* — the dispatch is impossible to hit for custom smart
pointers. Raw pointers plus generated forwarding overloads sidestep this.
This is recorded as design debt §4.2 in `STATUS.md`.

## Errors

VTK routes its output window into a buffer at module init. Every
high-level call (`clip`, `slice`, `read_vtu`, …) ends in `update!`, which
throws with VTK's message if anything was reported — so a failing pipeline
raises instead of returning half-baked data.

## The next layer (experimental)

`gen/wrapit/` drives [WrapIt](https://github.com/grasph/wrapit) to generate
the same C++ surface from VTK headers automatically (63 classes / 1250+
methods for the CFD subset). See [The WrapIt driver](wrapit.md).
