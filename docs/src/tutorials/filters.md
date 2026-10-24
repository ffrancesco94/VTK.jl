# Tutorial: filter pipelines

Filters are where VTK earns its keep. VTK.jl wraps the CFD workhorses
behind small functions that take a grid and return a new one.

## Setup: the oracle mesh

All examples use the unit hex with `T = x+y+z` from the
[mesh tutorial](mesh.md):

```julia
using VTK

function hex_mesh()
    pts = VTK.Points()
    VTK.npoints!(pts, 8)
    corners = [(0,0,0),(1,0,0),(1,1,0),(0,1,0),
               (0,0,1),(1,0,1),(1,1,1),(0,1,1)]
    for (i,c) in enumerate(corners); pts[i] = c; end
    grid = VTK.UnstructuredGrid()
    VTK.set_points!(grid, pts)
    VTK.allocate!(grid, 1)
    VTK.insert_cell!(grid, VTK.VTKCellTypes.VTK_HEXAHEDRON, collect(0:7))
    T = VTK.data_array(Float64, 1)
    VTK.resize!(T, 8)
    T[1, :] = Float64.(sum.(corners))
    VTK.name!(T, "temperature")
    VTK.add_array!(VTK.point_data(grid), T)
    return grid
end

grid = hex_mesh()
```

## Clip

`clip` keeps the region where the implicit function is negative; flip with
`insideout`:

```julia
pl = VTK.plane((1, 0, 0), (1, 1, 1))     # f = x+y+z-1

tetra = VTK.clip(grid, pl; insideout = true)
VTK.ncells(tetra), VTK.npoints(tetra)    # (1, 4) — exactly x+y+z ≤ 1

rest = VTK.clip(grid, pl)                # the complement
VTK.ncells(rest)                         # 8
```

Every high-level call runs `update!` internally, which executes the filter
and throws if VTK reported any error — pipelines fail loudly, not silently.

## Slice

Cross-sections where the function vanishes come back as poly data:

```julia
mid = VTK.slice(grid, VTK.plane((0.5, 0, 0), (1, 0, 0)))
VTK.npoints(mid)        # 4 — the unit square
```

## Contour

Isosurfaces of the active scalar; pick the array by name with `scalars=`:

```julia
iso = VTK.contour(grid, [1.5]; scalars = "temperature")
VTK.npoints(iso) > 0    # hex's mid-surface through the x+y+z=1.5 plane
```

`contour(grid, [v1, v2, ...])` extracts several isosurfaces in one pass.

## Cell ↔ point data

```julia
# constant per-cell field → point interpolation stays constant
cd = VTK.data_array(Float64, 1)
VTK.resize!(cd, 1)
cd[1, 1] = 2.5
VTK.name!(cd, "k")
VTK.add_array!(VTK.cell_data(grid), cd)

cvt = VTK.UnstructuredGrid(VTK.cell_to_point(grid))   # downcast to access
VTK.field_array(VTK.point_data(cvt), "k")[1, :]       # all 2.5

# linear field averaged back to cells: mean of x+y+z over each hex = 1.5
back = VTK.UnstructuredGrid(VTK.point_to_cell(grid))
VTK.field_array(VTK.cell_data(back), "temperature")[1, :]   # 1.5
```

`cell_to_point`/`point_to_cell` return `vtkDataSet` — downcast with
`UnstructuredGrid(obj)` / `PolyData(obj)` / `ImageData(obj)` to reach the
concrete API.

## Extracting surfaces

```julia
surf = VTK.extract_surface(grid)     # vtkPolyData with the 8 boundary points
VTK.npoints(surf)                    # 8
```

`extract_surface` is the workhorse for turning volumetric output into
something for `.vtp`/ParaView.

## Chaining it together

```julia
VTK.write_vtp(
    VTK.extract_surface(VTK.clip(grid, VTK.plane((0.5,0,0), (1,0,0)))),
    "half_hex_surf.vtp")
```

That's the whole story: read → transform → extract → write, with every
intermediate a first-class object you can inspect.

Under the hood: [architecture](../implementation/architecture.md) ·
[memory model](../implementation/ownership.md) ·
[zero-copy views](../implementation/zerocopy.md).
