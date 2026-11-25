using VTK
using Test

struct NotAVTKHandle end

@testset "Stage 0 input validation" begin
    pts = VTK.Points()
    @test_throws ArgumentError VTK.data_array(Float64, 0)
    @test_throws ArgumentError VTK.data_array(Float64, -1)
    @test_throws ArgumentError VTK.resize!(VTK.data_array(Float64), -1)
    @test_throws ArgumentError VTK.npoints!(pts, -1)
    VTK.npoints!(pts, 4)
    for (i, xyz) in enumerate(((0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)))
        pts[i] = xyz
    end
    @test_throws BoundsError pts[0] = (0, 0, 0)
    @test_throws BoundsError pts[5] = (0, 0, 0)
    @test_throws ArgumentError pts[1] = (0, 0)
    @test_throws ArgumentError pts[1] = (0, 0, "bad")

    grid = VTK.UnstructuredGrid()
    VTK.set_points!(grid, pts)
    @test_throws ArgumentError VTK.allocate!(grid, -1)
    VTK.allocate!(grid, 1)
    @test_throws ArgumentError VTK.insert_cell!(grid, VTK.VTK_TETRA, [0, 1, 2])
    @test_throws ArgumentError VTK.insert_cell!(grid, VTK.VTK_TETRA, [0, 1, 2, 4])
    @test_throws ArgumentError VTK.insert_cell!(grid, VTK.VTK_TETRA, [0, 1, 2, -1])
    @test_throws ArgumentError VTK.insert_cell!(grid, 999, [0, 1, 2, 3])
    @test VTK.ncells(grid) == 0
    VTK.insert_cell!(grid, VTK.VTK_TETRA, [0, 1, 2, 3])
    @test VTK.ncells(grid) == 1
    @test_throws BoundsError VTK.point_coordinates(grid, 0)
    @test_throws BoundsError VTK.point_coordinates(grid, 5)
    @test_throws BoundsError VTK.cell_type(grid, 0)
    @test_throws BoundsError VTK.cell_connectivity(grid, 2)

    @test_throws ArgumentError VTK.MultiBlockDataSet(-1)
    mb = VTK.MultiBlockDataSet(1)
    @test_throws BoundsError VTK.set_block!(mb, 0, grid)
    @test_throws BoundsError VTK.set_block!(mb, 2, grid)

    @test_throws MethodError size(NotAVTKHandle())
    @test_throws MethodError length(NotAVTKHandle())
    @test_throws MethodError NotAVTKHandle()[1] = (0, 0, 0)

    @test_throws ArgumentError VTK.plane((0, 0), (1, 0, 0))
    @test_throws ArgumentError VTK.plane((0, 0, 0), (1, 0))
    @test_throws ArgumentError VTK.line_source((0, 0), (1, 1, 1))
    @test_throws ArgumentError VTK.line_source((0, 0, 0), (1, 1, 1); resolution=0)
    @test_throws ArgumentError VTK.sample_over_line(
        grid, (0, 0, 0), (1, 1, 1); resolution=-1)
    @test !isdefined(VTK, :particle_tracer)
    @test isdefined(VTK.Experimental, :particle_tracer)
end

@testset "Stage 0 field and multiblock contracts" begin
    pts = VTK.Points()
    VTK.npoints!(pts, 1)
    pts[1] = (0, 0, 0)
    grid = VTK.UnstructuredGrid()
    VTK.set_points!(grid, pts)

    for association in (VTK.point_data(grid), VTK.cell_data(grid))
        a = VTK.data_array(Float64)
        VTK.name!(a, "shared")
        VTK.resize!(a, 1)
        a[1, 1] = 2.0
        VTK.add_array!(association, a)
    end
    VTK.remove_array!(grid, "shared")
    @test VTK.field_array(VTK.point_data(grid), "shared") === nothing
    @test VTK.field_array(VTK.cell_data(grid), "shared") === nothing
    @test_throws ArgumentError VTK.remove_array!(grid, "shared"; point=false, cell=false)

    child = VTK.block(let parent = VTK.MultiBlockDataSet(1)
        VTK.set_block!(parent, 1, grid)
        parent
    end, 1)
    grid = nothing
    for _ in 1:3
        GC.gc(true)
    end
    @test VTK.npoints(child) == 1

    parent = VTK.MultiBlockDataSet(1)
    VTK.set_block!(parent, 1, child)
    child = nothing
    for _ in 1:3
        GC.gc(true)
    end
    @test VTK.npoints(VTK.block(parent, 1)) == 1
end

@testset "Stage 0 downcast and unsupported-type policy" begin
    generic = VTK.GenericDataObjectForTesting()
    fallback = VTK.downcast(generic)
    @test VTK.GetClassName(fallback) == "vtkDataObject"
    @test fallback isa VTK.CxxWrap.CxxWrapCore.SmartPointer

    derived = VTK.DerivedPolyDataForTesting()
    @test VTK.GetClassName(derived) == "vtkJuliaDerivedPolyData"
    @test VTK.downcast(derived) isa VTK.vtkSmartPointerAllocated{VTK.vtkPolyData}
    @test_throws VTK.VTKTypeError VTK.downcast(VTK.NullDataObjectForTesting())
    @test_throws VTK.VTKTypeError VTK.PolyData(VTK.UnstructuredGrid())

    grid = VTK.UnstructuredGrid()
    VTK.AddStringArrayForTesting(VTK.point_data(grid), "labels")
    @test VTK.HasArray(VTK.point_data(grid), "labels")
    @test_throws VTK.VTKUnsupportedTypeError VTK.field_array(VTK.point_data(grid), "labels")
    @test_throws VTK.VTKUnsupportedTypeError VTK.field_array_raw(VTK.point_data(grid), "labels")
   
end
