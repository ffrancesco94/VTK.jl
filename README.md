# VTK.jl

Julia bindings for a CFD-oriented subset of [VTK](https://vtk.org) 9.7: data
model, XML I/O, and manipulation filters (clip, slice, cell↔point data
conversion, contour, surface extraction). No rendering, no MPI-aware API.

Status: early development (phase 0/1). Built on `VTK_jll` (binaries) +
`CxxWrap.jl` (bindings).

## Building

The C++ binding module must be built once against the `VTK_jll` artifact
(needs a C++17 toolchain — `g++` or `clang`):

```sh
julia --project=. gen/build_wrapper.jl
```

This drives the WrapIt-based generator ([`gen/wrapit`](gen/wrapit)) —
generate CxxWrap bindings from the VTK headers, merge the hand shim, compile —
and installs the result at `wrapper/build/libvtk_julia.so`, the default
location loaded by the package.

- Fallback: the legacy hand-written CMake wrapper is still available via
  `julia --project=. gen/build_wrapper_cmake.jl`.
- Override the loaded library with the `VTKJL_LIB` environment variable.
  Note Julia's precompile cache does **not** track `VTKJL_LIB`: after
  switching libraries, clear the package cache
  (`rm -rf ~/.julia/compiled/v1.*/VTK`) or you silently keep testing the
  previous one.

## Usage

```julia
using VTK

ug = VTK.read_vtu("case.vtu")          # vtkUnstructuredGrid
p = VTK.field_array(VTK.point_data(ug), "p")   # VTKDataArray{Float64}

# typed, zero-copy AbstractMatrix of shape (ncomponents, ntuples)
p[1, 1:10] .= 0.0                      # writes through to the VTK array
sum_p = sum(p)                         # type-stable indexing

# creating arrays from Julia
T = VTK.data_array(Float64, 3)         # new 3-component Float64 array
VTK.resize!(T, 1000)

pl = VTK.plane((0.5, 0.0, 0.0), (1.0, 0.0, 0.0))
clipped = VTK.clip(ug, pl)             # vtkUnstructuredGrid
sl = VTK.slice(ug, pl)                 # vtkPolyData cross-section
cvt = VTK.UnstructuredGrid(VTK.cell_to_point(ug))
VTK.write_vtu(clipped, "clipped.vtu")  # zlib-compressed XML output

# cells and coordinates as plain Julia data (VTKBase MeshCells, 1-based)
cs = VTK.cells(ug)                     # Vector{MeshCell}
xy = VTK.coordinates(ug)               # zero-copy 3×n VTKDataArray
copy = VTK.UnstructuredGrid(xy, cs)    # reconstruct from (points, cells)

# the same description feeds WriteVTK directly:
#   WriteVTK.vtk_grid("copy", Matrix(xy), cs) |> WriteVTK.vtk_save
```

## Design notes

- **Ownership**: factories and outputs return `vtkSmartPointer{T}`, registered
  with CxxWrap as a smart pointer; Julia finalizers release references.
  Borrowed raw pointers are never exposed in the public API.
- **vtkDataArray**: zero-copy views of the AOS storage are exposed via
  `raw_data`/`data` (component-fastest layout, i.e. `(ncomp, ntuples)`
  column-major). Views are derived from an owning `VTKDataArray` wrapper
  ("wrapper-owns-everything"), so they stay valid even if the dataset or
  original handle is dropped — no finalizers on views (see the docs for
  why). After `resize!`, previously obtained views are invalidated by
  reallocation.
- **Cell types**: the cell vocabulary is VTKBase's `VTKCellTypes` registry
  (shared with ReadVTK/WriteVTK); `cell`/`cells`/`eachcell` return VTKBase
  `MeshCell`s with 1-based connectivity, directly consumable by
  `WriteVTK.vtk_grid`.
- **Type hierarchy**: wrapped types mirror the VTK inheritance chain, so
  `vtkUnstructuredGrid <: vtkPointSet <: vtkDataSet` etc. on the Julia side.
- **Error handling**: `update!` (used by all high-level filter calls) throws
  if VTK reported any error during execution.

## Testing

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Tests include analytic oracles (clip of a unit hex against a plane yields the
tetrahedron x+y+z ≤ 1) and cross-validation against ReadVTK.jl/WriteVTK.jl,
independent pure-Julia VTK readers/writers.

## Documentation

The documentation (tutorials, implementation notes, API reference) is built
with [DocumenterVitepress.jl](https://github.com/LuxDL/DocumenterVitepress.jl):

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'   # once
julia --project=docs docs/make.jl                        # renders to docs/build/1/
```

Deployment to GitHub Pages is opt-in (`DOCS_DEPLOY=true julia --project=docs docs/make.jl`).
The full WrapIt spike write-up with upstream bug reports lives in
[docs/wrapit-spike.md](docs/wrapit-spike.md).
