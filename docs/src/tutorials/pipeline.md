# Tutorial: an end-to-end CFD workflow

Read a mesh, inspect its fields, slice it, and write the slice — the
smallest realistic VTK.jl pipeline. Everything below is runnable as-is
(adapt the file paths).

## 1. Read the mesh and look around

```julia
using VTK

grid = VTK.read_vtu("case.vtu")     # owning handle; stays alive while you use it
VTK.npoints(grid), VTK.ncells(grid)

# What fields are on the points / cells?
pd = VTK.point_data(grid)
VTK.field_array_names(pd)

p = VTK.field_array(pd, "p")        # typed zero-copy view, or nothing if absent
size(p)                             # (ncomponents, ntuples) = (1, npoints)
```

`field_array` returns a `VTKDataArray{T}` — an `AbstractMatrix{T}` backed
directly by VTK's memory. Indexing `p[1, i]` reads the pressure at point
`i`; `p[:, i]` is the vector at point `i` for vector fields. No copies.

## 2. Slice the mesh

`slice` cuts a grid with an implicit plane and returns the cut surface as
poly data:

```julia
plane = VTK.plane((0.5, 0.0, 0.0),   # origin: x = 0.5
                  (1.0, 0.0, 0.0))   # normal: along x
surf = VTK.slice(grid, plane)        # vtkPolyData
VTK.npoints(surf), VTK.ncells(surf)
```

The slice inherits the input's point data — the pressure field is already
there:

```julia
sp = VTK.field_array(VTK.point_data(surf), "p")
```

Other one-liners in the same spirit: `clip` (volume clipped by a plane),
`contour` (isosurface of a scalar), `extract_surface` (boundary faces).
See the [filter pipelines](filters.md) tutorial.

## 3. Write the result

```julia
VTK.write_vtp(surf, "slice_x05.vtp")   # zlib-compressed, ParaView-ready
```

Or keep it in a multiblock together with the original mesh:

```julia
mb = VTK.MultiBlockDataSet(2)
VTK.set_block!(mb, 1, grid)
VTK.set_block!(mb, 2, surf)
VTK.write_vtm(mb, "case_with_slice.vtm")   # writes .vtm + sidecar files
```

Reading multiblock back: `mb = VTK.read_vtm("case_with_slice.vtm")`, then
`VTK.block(mb, i)` returns each block downcast to its concrete type.

## 4. Interop with the pure-Julia ecosystem

- `VTK.cells(grid)` returns VTKBase `MeshCell`s — feed them straight to
  `WriteVTK.vtk_grid` if a colleague wants a file from a script that does
  not build VTK.
- Conversely, `VTK.read_vtu` reads anything `WriteVTK` (or ParaView, or
  CFD solvers) emit in `.vtu`.
- The test suite cross-validates both directions against ReadVTK.jl and
  WriteVTK.jl, so a file VTK.jl writes is one any tool reads.

## Recap

```julia
using VTK
grid = VTK.read_vtu("case.vtu")
surf = VTK.slice(grid, VTK.plane((0.5, 0, 0), (1, 0, 0)))
VTK.write_vtp(surf, "slice_x05.vtp")
```

Three lines: read → filter → write. To wrap a new filter so it joins this
pipeline, see [Extending the bindings](../implementation/extending.md).
