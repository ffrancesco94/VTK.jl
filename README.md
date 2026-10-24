# VTK.jl

Julia bindings for a CFD-oriented subset of [VTK](https://vtk.org) 9.7: data
model, XML I/O, and manipulation filters (clip, slice, cell↔point data
conversion, contour, surface extraction). No rendering, no MPI-aware API.

Status: early development (phase 0/1). Built on `VTK_jll` (binaries) +
`CxxWrap.jl` (bindings).

## Building

The C++ binding module must be built once against the `VTK_jll` artifact:

```sh
julia --project=. gen/build_wrapper.jl
```

This produces `wrapper/build/libvtk_julia.so` (override the location with the
`VTKJL_LIB` environment variable).

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
- **vtkDataArray**: a flat zero-copy view of the AOS storage is exposed via
  `raw_data`/`data` (component-fastest layout, i.e. `(ncomp, ntuples)`
  column-major). Views carry a finalizer that keeps the owning array alive,
  so they stay valid even if the dataset is dropped (after `resize!`,
  previously obtained views are invalidated by reallocation).
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
