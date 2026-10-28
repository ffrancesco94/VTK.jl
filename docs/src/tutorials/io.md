# Tutorial: reading & writing files

VTK.jl speaks the VTK XML formats — unstructured (`.vtu`), poly data
(`.vtp`), image data (`.vti`), rectilinear (`.vtr`), and structured
(`.vts`) grids — and interops cleanly with the pure-Julia ecosystem.

## Reading VTK files

```julia
using VTK

ug = VTK.read_vtu("case.vtu")        # vtkUnstructuredGrid (owning ref)
VTK.npoints(ug), VTK.ncells(ug)

pd = VTK.point_data(ug)
names = VTK.field_array_names(pd)
p = VTK.field_array(pd, "p")         # typed zero-copy view, or nothing
```

`read_vtp` does the same for poly data; `read_vti`/`read_vtr`/`read_vts`
read image, rectilinear, and curvilinear structured grids; `read_vtm`
reads multiblock containers (see below).  For CFD workflows,
`read_ensight` reads EnSight Gold case files, `read_cgns` reads CGNS
files, and `read_pvtp` reads parallel PVTK poly-data summaries — all
returning `vtkMultiBlockDataSet` (or `vtkPolyData` for `read_pvtp`).
Readers return owning smart pointers, so the grid stays alive as long as
you hold it.

## Writing VTK files

```julia
VTK.write_vtu(ug, "out.vtu")                      # zlib-compressed appended
VTK.write_vtu(ug, "out_raw.vtu"; raw_appended = true)  # uncompressed appended
VTK.write_vtp(poly, "surf.vtp")
VTK.write_vti(img, "img.vti")                     # structured formats
VTK.write_vtr(rg, "rg.vtr")
VTK.write_vts(sg, "sg.vts")
VTK.write_vtm(mb, "case.vtm")                     # multiblock container
```

The default mode writes zlib-compressed appended data — ideal for ParaView.
The `raw_appended` mode is byte-compatible with what
[ReadVTK.jl](https://github.com/JuliaVTK/ReadVTK.jl) parses; the test suite
cross-validates in both directions, so a file written by VTK.jl is verified
by an independent pure-Julia reader (and vice versa).

## Multiblock files (.vtm)

A `.vtm` file groups several grids (mixed types) into one assembly; VTK
writes the container plus one sidecar file per block:

```julia
mb = VTK.read_vtm("case.vtm")
VTK.nblocks(mb)                  # number of blocks
g1 = VTK.block(mb, 1)            # block 1, downcast to its concrete type
VTK.npoints(g1)

mb2 = VTK.MultiBlockDataSet(2)   # assemble: 2 empty slots
VTK.set_block!(mb2, 1, grid)     # fill them (1-based)
VTK.set_block!(mb2, 2, surface)
VTK.write_vtm(mb2, "out.vtm")
```

Blocks are borrowed views owned by the multiblock dataset — keep `mb`
alive while using them. Note that files written by other tools may nest
blocks one level deeper than expected (e.g. WriteVTK puts each named group
in its own sub-block); `nblocks`/`block` compose, so just descend until
you reach a data grid.

## Interop with WriteVTK.jl

The cell/ point accessors return VTKBase's `MeshCell` — the same
vocabulary WriteVTK speaks — so a VTK.jl grid can be re-emitted by
WriteVTK without any translation layer:

```julia
using VTK, WriteVTK

grid = VTK.read_vtu("case.vtu")

WriteVTK.vtk_grid("copy", Matrix(VTK.coordinates(grid)), VTK.cells(grid)) do vtk
    WriteVTK.vtk_save(vtk)
end
```

and the round trip back:

```julia
rebuilt = VTK.UnstructuredGrid(VTK.coordinates(grid), VTK.cells(grid))
VTK.ncells(rebuilt) == VTK.ncells(grid)   # true
```

`UnstructuredGrid(points, cells)` accepts any `3×n` real matrix (or the
zero-copy `VTKDataArray` view) and a vector of `MeshCell`s; connectivity is
1-based, following WriteVTK's convention.

## Cell type registry

Cell types are [VTKBase](https://github.com/JuliaVTK/VTKBase.jl)'s
`VTKCellTypes` singletons — the shared registry of ReadVTK/WriteVTK:

```julia
VTK.cell_type(grid, 1)                    # VTKCellType("VTK_HEXAHEDRON", 0x0c, 8)
VTK.cell_type(grid, 1).vtk_id             # 12
VTK.VTKCellTypes.VTKCellType(12)          # reverse lookup by id
```

Custom cell insertion uses the same vocabulary:

```julia
VTK.insert_cell!(grid, VTK.VTKCellTypes.VTK_TETRA, [0, 1, 2, 3])
```

## What is *not* covered (yet)

Legacy `.vtk` and parallel unstructured-grid readers (`.pvtu`) are
unwrapped — see the roadmap in `STATUS.md`.  For structured data, the
pragmatic path today is going through WriteVTK/ReadVTK and converting
via the constructors above.

Next: [filter pipelines](filters.md).
