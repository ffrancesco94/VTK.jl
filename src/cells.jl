# cells.jl — cell type registry (VTKBase vocabulary), cell/point iterators,
# and conversion to/from plain Julia mesh descriptions (VTKBase MeshCell),
# which interop directly with WriteVTK/ReadVTK.

using VTKBase: VTKBase, VTKCellTypes, MeshCell

# VTKBase's cell type registry: names <-> VTK ids, e.g. VTKCellTypes.VTK_HEXAHEDRON.
const VTKCellType = VTKCellTypes.VTKCellType

"""
    cell_type(grid, i) -> VTKCellType

Type of the i-th cell (1-based) as a VTKBase `VTKCellType` (has `.vtk_id`
and `VTKCellTypes.name`).
"""
cell_type(grid, i::Integer) =
    VTKCellTypes.VTKCellType(GetCellTypeId(_cp(vtkDataSet, grid), i - 1))

"""
    cell_connectivity(grid, i) -> Vector{Int}

1-based point indices of the i-th cell (1-based), following WriteVTK's
connectivity convention.
"""
cell_connectivity(grid, i::Integer) =
    Int.(GetCellPointIds(_cp(vtkDataSet, grid), i - 1)) .+ 1

"""
    cell(grid, i) -> MeshCell

The i-th cell as a VTKBase `MeshCell` (1-based connectivity).
"""
cell(grid, i::Integer) = MeshCell(cell_type(grid, i), cell_connectivity(grid, i))

"""
    cells(grid) -> Vector{MeshCell}

All cells of the grid as VTKBase `MeshCell`s, directly consumable by
`WriteVTK.vtk_grid(filename, points, cells)`.
"""
cells(grid) = [cell(grid, i) for i in 1:ncells(grid)]

"""
    eachcell(grid)

Lazily iterate over the cells of `grid` as `MeshCell`s.
"""
eachcell(grid) = (cell(grid, i) for i in 1:ncells(grid))

"""
    eachpoint(grid)

Lazily iterate over point coordinates as `(x, y, z)` tuples.
"""
eachpoint(grid) = (point_coordinates(grid, i) for i in 1:npoints(grid))

"""
    coordinates(grid) -> VTKDataArray{T}

Zero-copy typed `3×n` view of the grid's point coordinates (component-fastest,
i.e. `coordinates(grid)[1, j]` is the x of point j).
"""
coordinates(grid) = points_array(points(grid))

"""
    UnstructuredGrid(points, cells) -> vtkUnstructuredGrid

Construct an unstructured grid from a `3×n` coordinate matrix and a vector of
VTKBase `MeshCell`s (e.g. from `cells(grid)`), with 1-based connectivity —
the inverse of `cells`/`coordinates`.
"""
function UnstructuredGrid(pts::AbstractMatrix{<:Real},
                          cl::AbstractVector{<:MeshCell})
    size(pts, 1) == 3 || throw(ArgumentError(
        "points must be a 3×n coordinate matrix, got $(size(pts, 1))×$(size(pts, 2))"))
    grid = UnstructuredGrid()
    allocate!(grid, length(cl))
    p = Points()
    npoints!(p, size(pts, 2))
    for j in axes(pts, 2)
        p[j] = ntuple(k -> Float64(pts[k, j]), 3)
    end
    set_points!(grid, p)
    for c in cl
        insert_cell!(grid, Int(c.ctype.vtk_id), collect(c.connectivity) .- 1)
    end
    return grid
end

# Accept VTKCellType directly in insert_cell! (uses the VTKBase vocabulary).
insert_cell!(grid, celltype::VTKCellTypes.VTKCellType, point_ids) =
    insert_cell!(grid, Int(celltype.vtk_id), point_ids)
