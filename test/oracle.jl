using VTK
using Test
using ReadVTK

# Independent-oracle test: files written by VTK.jl are verified with ReadVTK,
# a pure-Julia VTK reader, and files written by WriteVTK are read via VTK.jl.

@testset "independent oracle (ReadVTK.jl)" begin
    ug = VTK.UnstructuredGrid()
    pts = VTK.Points()
    VTK.npoints!(pts, 8)
    coords = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
        (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
    for (i, c) in enumerate(coords)
        pts[i] = c
    end
    VTK.set_points!(ug, pts)
    VTK.allocate!(ug, 1)
    VTK.insert_cell!(ug, VTK.VTK_HEXAHEDRON, 0:7)
    da = VTK.DoubleArray_new(1)
    VTK.name!(da, "temperature")
    VTK.resize!(da, 8)
    vec(VTK.data(da))[:] .= collect(0.0:7.0)
    VTK.add_array!(VTK.point_data(ug), da)

    mktempdir() do dir
        path = joinpath(dir, "hex.vtu")
        VTK.write_vtu(ug, path; raw_appended = true) # raw appended: ReadVTK-compatible

        f = ReadVTK.VTKFile(path)
        @test ReadVTK.get_points(f) ≈ reduce(hcat, [[c...] for c in coords])
        pd = ReadVTK.get_point_data(f)
        @test ReadVTK.get_data(pd["temperature"]) ≈ 0.0:7.0
    end
end

@testset "read WriteVTK.jl output" begin
    using WriteVTK
    mktempdir() do dir
        coords = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
        points = reduce(hcat, [[Float64.(c)...] for c in coords])
        cells = [MeshCell(VTKCellTypes.VTK_HEXAHEDRON, 1:8)]
        path = joinpath(dir, "w.vtu")
        vtk_grid(path[1:end-4], points, cells) do vtk
            vtk["temperature", VTKPointData()] = collect(0.0:7.0)
        end

        ug = VTK.read_vtu(path)
        @test VTK.npoints(ug) == 8
        @test VTK.ncells(ug) == 1
        da = VTK.field_array(VTK.point_data(ug), "temperature")
        @test vec(VTK.data(da)) ≈ 0.0:7.0
        c = VTK.data(VTK.points_array(VTK.points(ug)))
        @test c ≈ points
    end
end
