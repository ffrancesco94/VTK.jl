# Cells: type registry (VTKBase vocabulary), iterators, plain-data converters.
using WriteVTK

@testset "cells" begin
    # unit hex + an interior-diagonal tetrahedron, matching the oracle setup
    grid = VTK.UnstructuredGrid()
    VTK.allocate!(grid, 2)
    pts = VTK.Points()
    VTK.npoints!(pts, 8)
    corners = [(0,0,0), (1,0,0), (1,1,0), (0,1,0),
               (0,0,1), (1,0,1), (1,1,1), (0,1,1)]
    for (i, c) in enumerate(corners)
        pts[i] = c
    end
    VTK.set_points!(grid, pts)
    VTK.insert_cell!(grid, VTK.VTKCellTypes.VTK_HEXAHEDRON, [0,1,2,3,4,5,6,7])
    VTK.insert_cell!(grid, VTK.VTKCellTypes.VTK_TETRA, [0,1,2,4])

    # registry: ids and names come from VTKBase
    @test VTK.cell_type(grid, 1) == VTK.VTKCellTypes.VTK_HEXAHEDRON
    @test VTK.cell_type(grid, 2) == VTK.VTKCellTypes.VTK_TETRA
    @test VTK.cell_type(grid, 1).vtk_id == 12
    @test VTK.cell_type(grid, 2).vtk_id == 10

    # connectivity is 1-based (WriteVTK convention)
    @test VTK.cell_connectivity(grid, 2) == [1, 2, 3, 5]

    # MeshCell has no == (struct equality falls back to ===); compare fields
    c1 = VTK.cell(grid, 1)
    @test c1 isa VTK.MeshCell
    @test c1.ctype == VTK.VTKCellTypes.VTK_HEXAHEDRON
    @test c1.connectivity == [1,2,3,4,5,6,7,8]
    @test [c.ctype for c in VTK.eachcell(grid)] == [c.ctype for c in VTK.cells(grid)]
    @test [c.connectivity for c in VTK.eachcell(grid)] ==
          [c.connectivity for c in VTK.cells(grid)]
    @test length(VTK.cells(grid)) == VTK.ncells(grid)

    # points (vtkPoints stores coordinates as Float32 by default)
    @test collect(VTK.eachpoint(grid)) == corners
    coords = VTK.coordinates(grid)
    @test coords isa VTK.VTKDataArray{Float32}
    @test size(coords) == (3, 8)
    @test coords[1, 2] == 1.0  # x of point 2
    @test coords[3, 5] == 1.0  # z of point 5

    # constructor from plain data: inverse of cells/coordinates
    grid2 = VTK.UnstructuredGrid(VTK.coordinates(grid), VTK.cells(grid))
    @test VTK.ncells(grid2) == 2
    @test VTK.npoints(grid2) == 8
    @test [c.ctype for c in VTK.cells(grid2)] == [c.ctype for c in VTK.cells(grid)]
    @test [c.connectivity for c in VTK.cells(grid2)] == [c.connectivity for c in VTK.cells(grid)]
    @test collect(VTK.eachpoint(grid2)) == corners

    # wrong point-matrix shape is rejected
    @test_throws ArgumentError VTK.UnstructuredGrid(zeros(2, 8), VTK.cells(grid))
end

@testset "WriteVTK interop" begin
    # VTK.jl -> WriteVTK: describe our grid with VTKBase MeshCells and let
    # WriteVTK write it; then read it back with our own reader.
    grid = VTK.UnstructuredGrid()
    VTK.allocate!(grid, 1)
    pts = VTK.Points()
    VTK.npoints!(pts, 4)
    pts[1] = (0,0,0); pts[2] = (1,0,0); pts[3] = (0,1,0); pts[4] = (0,0,1)
    VTK.set_points!(grid, pts)
    VTK.insert_cell!(grid, VTK.VTKCellTypes.VTK_TETRA, [0,1,2,3])

    path = joinpath(@__DIR__, "tmp_writevtk_interop")  # WriteVTK appends .vtu
    vtk = WriteVTK.vtk_grid(path, Matrix(VTK.coordinates(grid)), VTK.cells(grid))
    WriteVTK.vtk_save(vtk)
    grid2 = VTK.read_vtu(path * ".vtu")
    @test VTK.ncells(grid2) == 1
    @test VTK.npoints(grid2) == 4
    @test VTK.cell_type(grid2, 1) == VTK.VTKCellTypes.VTK_TETRA
    @test collect(VTK.eachpoint(grid2)) ==
        [(0,0,0), (1,0,0), (0,1,0), (0,0,1)]
    rm(path * ".vtu")
end

@testset "views own their storage (wrapper-owns)" begin
    # Hardened ownership: views handed out by data()/raw_data() are derived
    # from an OWNING VTKDataArray wrapper, so dropping every direct owner
    # reference must not invalidate them. Finalizers of *other* objects run
    # during these GCs; the view -> wrapper -> smart-pointer chain must keep
    # the C++ array alive structurally (no finalizers on views, see STATUS).
    da = VTK.data_array(Float64, 1)
    VTK.resize!(da, 4)
    da[1, :] = [1.0, 2.0, 3.0, 4.0]
    flat = VTK.raw_data(da.obj)   # flat view of an owning wrapper
    mat = VTK.data(da.obj)        # owning wrapper itself
    da = nothing
    for _ in 1:3
        GC.gc(true)
    end
    @test flat == [1.0, 2.0, 3.0, 4.0]
    @test mat == [1.0 2.0 3.0 4.0]

    # same through the typed wrapper: raw_data(a) is now a flat vec(a)
    a = VTK.data_array(Float64, 1)
    VTK.resize!(a, 2)
    a[1, :] = [10.0, 20.0]
    v = VTK.raw_data(a)
    a = nothing
    for _ in 1:3
        GC.gc(true)
    end
    @test v == [10.0, 20.0]

    # and through a grid's field arrays: drop the whole grid
    grid = VTK.UnstructuredGrid()
    pts = VTK.Points()
    VTK.npoints!(pts, 3)
    pts[1] = (0,0,0); pts[2] = (1,0,0); pts[3] = (0,1,0)
    VTK.set_points!(grid, pts)
    arr = VTK.data_array(Float64, 1)
    VTK.resize!(arr, 3)
    arr[1, :] = [5.0, 6.0, 7.0]
    VTK.name!(arr, "myvals")
    VTK.add_array!(VTK.point_data(grid), arr)
    view_of_grid = VTK.data(VTK.field_array_raw(VTK.point_data(grid), "myvals"))
    grid = nothing
    for _ in 1:3
        GC.gc(true)
    end
    @test view_of_grid == [5.0 6.0 7.0]
end
