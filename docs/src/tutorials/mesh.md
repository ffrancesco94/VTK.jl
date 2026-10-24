# Tutorial: building a mesh

This tutorial builds a unit-cube hexahedron mesh from plain Julia data,
attaches a field, and writes it to disk. It mirrors the setup used by the
test suite's analytic oracles.

## The recipe

A grid needs three ingredients: points, cells, and (optionally) field data.

```julia
using VTK

# 1. Points ----------------------------------------------------------------
pts = VTK.Points()
VTK.npoints!(pts, 8)
corners = [(0,0,0), (1,0,0), (1,1,0), (0,1,0),
           (0,0,1), (1,0,1), (1,1,1), (0,1,1)]
for (i, c) in enumerate(corners)
    pts[i] = c          # 1-based indexing; VTK stores Float32 coordinates
end

# 2. Grid + cells ------------------------------------------------------------
grid = VTK.UnstructuredGrid()
VTK.set_points!(grid, pts)
VTK.allocate!(grid, 1)                       # reserve space for 1 cell

VTK.insert_cell!(grid, VTK.VTKCellTypes.VTK_HEXAHEDRON, [0, 1, 2, 3, 4, 5, 6, 7])
```

`insert_cell!` takes the cell type (a `VTKCellTypes.VTKCellType` from
[VTKBase](https://github.com/JuliaVTK/VTKBase.jl), or a raw VTK id like
`12`) and the connectivity as **0-based** point ids, following VTK
convention.

## Inspecting cells as plain data

The mesh can be read back as plain Julia objects — `cells` returns
`VTKBase.MeshCell`s with 1-based connectivity (WriteVTK convention), and
`coordinates` a zero-copy typed view of the coordinates:

```julia
cs = VTK.cells(grid)
# 1-element Vector{MeshCell}:
#  MeshCell(VTKCellType("VTK_HEXAHEDRON", 0x0c, 8), [1, 2, 3, 4, 5, 6, 7, 8])

xy = VTK.coordinates(grid)     # VTKDataArray{Float32} of size (3, 8)
xy[1, 2]                       # x of point 2 → 1.0f0
```

`VTK.eachcell(grid)` and `VTK.eachpoint(grid)` iterate lazily, and the
round-trip constructor rebuilds a grid from the same plain data:

```julia
copy = VTK.UnstructuredGrid(VTK.coordinates(grid), VTK.cells(grid))
```

## Attaching a field

```julia
T = VTK.data_array(Float64, 1)     # new 1-component Float64 array
VTK.resize!(T, 8)
T[1, :] = [0, 1, 2, 1, 1, 2, 3, 2]  # T = x + y + z at the corners
VTK.name!(T, "temperature")
VTK.add_array!(VTK.point_data(grid), T)
```

`VTK.data_array(T, ncomp)` is the generic typed factory (any scalar VTK
type: `Float32/64`, `Int32/64`, `UInt8`, …).

## Writing

```julia
VTK.write_vtu(grid, "hex.vtu")                # zlib-compressed appended data
VTK.write_vtu(grid, "hex_raw.vtu"; raw_appended = true)  # ReadVTK-compatible
```

The default writer output is what ParaView likes; the `raw_appended` mode is
what [ReadVTK.jl](https://github.com/JuliaVTK/ReadVTK.jl) can parse (see the
[I/O tutorial](io.md) for the full interop picture).

## What next?

- [Data arrays & fields](arrays.md) — typed views, zero-copy, resizing.
- [Filter pipelines](filters.md) — clip this cube against a plane and get
  the tetrahedron x+y+z ≤ 1, verified analytically.
