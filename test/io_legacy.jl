using VTK
using Test

# Legacy VTK format I/O (.vtk). Round-trips through VTK.jl's own
# reader/writer; the writer emits ASCII legacy format.

@testset "legacy VTK I/O" begin
    mktempdir() do dir
        # ---- unstructured grid round-trip ----
        coords = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
                  (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
        pts = VTK.Points()
        VTK.npoints!(pts, 8)
        for (i, c) in enumerate(coords)
            pts[i] = c
        end
        ug = VTK.UnstructuredGrid()
        VTK.set_points!(ug, pts)
        VTK.allocate!(ug, 1)
        VTK.insert_cell!(ug, VTK.VTK_HEXAHEDRON, 0:7)

        da = VTK.DoubleArray_new(1)
        VTK.name!(da, "temperature")
        VTK.resize!(da, 8)
        tvals = vec(VTK.data(da))
        for (i, c) in enumerate(coords)
            tvals[i] = sum(c)
        end
        VTK.add_array!(VTK.point_data(ug), da)

        path = joinpath(dir, "hex.vtk")
        VTK.write_legacy_vtk(ug, path)
        @test isfile(path)

        ug2 = VTK.read_legacy_vtk(path)
        @test ug2 isa VTK.vtkSmartPointerAllocated{VTK.vtkUnstructuredGrid}
        @test VTK.npoints(ug2) == 8
        @test VTK.ncells(ug2) == 1
        @test VTK.cell_type(ug2, 1).vtk_id == 12  # VTK_HEXAHEDRON

        da2 = VTK.field_array(VTK.point_data(ug2), "temperature")
        @test da2 !== nothing
        @test vec(VTK.data(da2)) ≈ [0, 1, 2, 1, 1, 2, 3, 2]

        # coordinates preserved
        c = VTK.data(VTK.points_array(VTK.points(ug2)))
        @test c[:, 1] == [0, 0, 0]
        @test c[:, 7] == [1, 1, 1]

        # ---- poly data round-trip ----
        # (skipped: PolyData() constructor not exposed; unstructured grid
        #  covers the generic reader/writer path)

        # ---- missing file error ----
        @test_throws Exception VTK.read_legacy_vtk(joinpath(dir, "nonexistent.vtk"))
    end
end
