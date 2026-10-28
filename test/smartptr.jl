@testset "generated smart-pointer overloads" begin
    pts = VTK.Points_new()
    VTK.SetNumberOfPoints(pts, 1)
    VTK.SetPoint(pts, 0, 1.0, 2.0, 3.0)
    @test VTK.GetPoint(pts, 0) == (1.0, 2.0, 3.0)

    grid = VTK.UnstructuredGrid_new()
    VTK.SetPoints(grid, pts)
    @test VTK.npoints(grid) == 1

    # Raw-pointer calls remain supported for low-level users and downcasts.
    @test VTK.GetNumberOfPoints(VTK._cp(VTK.vtkPointSet, grid)) == 1

    plane = VTK.plane((1.0, 0.0, 0.0), (1.0, 0.0, 0.0))
    clip = VTK.TableBasedClipDataSet_new()
    VTK.SetInputData(clip, grid)
    VTK.SetClipFunction(clip, plane)
    VTK.SetInsideOut(clip, true)
    VTK.Update(clip)
    @test VTK.GetOutput(clip) isa VTK.CxxWrap.CxxWrapCore.SmartPointer

    if isdefined(VTK, :InsideOutOn)
        VTK.InsideOutOff(clip)
        @test VTK.GetInsideOut(clip) == 0
        VTK.InsideOutOn(clip)
        @test VTK.GetInsideOut(clip) == 1
    end
end
