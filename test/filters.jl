using VTK
using Test

# A unit-cube hex mesh with the linear field T = x + y + z at its points.
function hex_mesh_with_temperature()
    pts = VTK.Points()
    VTK.npoints!(pts, 8)
    coords = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
        (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
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
    return ug
end

@testset "XML I/O roundtrip" begin
    ug = hex_mesh_with_temperature()
    mktempdir() do dir
        path = joinpath(dir, "hex.vtu")
        VTK.write_vtu(ug, path)
        @test isfile(path)

        ug2 = VTK.read_vtu(path)
        @test VTK.npoints(ug2) == 8
        @test VTK.ncells(ug2) == 1
        da2 = VTK.field_array(VTK.point_data(ug2), "temperature")
        @test da2 !== nothing
        t2 = vec(VTK.data(da2))
        @test t2 ≈ [0, 1, 2, 1, 1, 2, 3, 2]

        # coordinates preserved
        c = VTK.data(VTK.points_array(VTK.points(ug2)))
        @test c[:, 1] == [0, 0, 0]
        @test c[:, 7] == [1, 1, 1]

        # missing array name -> nothing
        @test VTK.field_array(VTK.point_data(ug2), "nope") === nothing
    end
end

@testset "filters" begin
    ug = hex_mesh_with_temperature()

    # clip: keep x+y+z <= 1 with insideout -> tetrahedron of volume 1/6
    p = VTK.plane((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
    clipped = VTK.clip(ug, p; insideout = true)
    @test VTK.ncells(clipped) == 1
    @test VTK.npoints(clipped) == 4
    c = VTK.data(VTK.points_array(VTK.points(clipped)))
    @test maximum(c[1, :] .+ c[2, :] .+ c[3, :]) <= 1.0 + 1e-12

    # the default side keeps the complement (contains the (1,1,1) vertex)
    other = VTK.clip(ug, p)
    c2 = VTK.data(VTK.points_array(VTK.points(other)))
    @test maximum(c2[1, :] .+ c2[1, :] .* 0 .+ c2[2, :] .+ c2[3, :]) ≈ 3.0

    # cell data -> point data of a constant field is constant
    cd = VTK.DoubleArray_new(1)
    VTK.name!(cd, "constant")
    VTK.resize!(cd, 1)
    vec(VTK.data(cd))[:] .= 2.5
    ugc = hex_mesh_with_temperature()
    VTK.add_array!(VTK.cell_data(ugc), cd)
    c2p = VTK.UnstructuredGrid(VTK.cell_to_point(ugc))
    arr = VTK.field_array(VTK.point_data(c2p), "constant")
    @test all(==(2.5), vec(VTK.data(arr)))

    # point data -> cell data of the linear field averages to 1.5 on the hex
    p2c = VTK.UnstructuredGrid(VTK.point_to_cell(ug))
    carr = VTK.field_array(VTK.cell_data(p2c), "temperature")
    @test vec(VTK.data(carr))[] ≈ 1.5

    # slice at x = 0.5: square cross-section
    pl = VTK.plane((0.5, 0.0, 0.0), (1.0, 0.0, 0.0))
    sl = VTK.slice(ug, pl)
    @test VTK.npoints(sl) == 4

    # contour of T at 1.5 (within [1,3] range, cuts the hex interior)
    surf = VTK.contour(ug, [1.5]; scalars = "temperature")
    @test VTK.npoints(surf) > 0
    cs = VTK.data(VTK.points_array(VTK.points(surf)))
    @test all(isapprox.(cs[1, :] .+ cs[2, :] .+ cs[3, :], 1.5; atol = 1e-8))

    # external surface of the hex
    ext = VTK.extract_surface(ug)
    @test VTK.npoints(ext) == 8

    # calculator: double the temperature field
    calc = VTK.calculator(ug; scalars = "temperature",
                          expression = "temperature * 2", result = "T2")
    arr = VTK.field_array(VTK.point_data(calc), "T2")
    @test arr !== nothing
    @test vec(VTK.data(arr)) ≈ 2 .* [0, 1, 2, 1, 1, 2, 3, 2]

    # GC stress across the full pipeline
    for _ in 1:50
        g = hex_mesh_with_temperature()
        VTK.clip(g, p; insideout = true)
    end
    GC.gc(true)
    @test VTK.npoints(ug) == 8
end

# Auto-generated shim (gen/wrapit/auto_shim.jl): factories and macro
# accessors derived from the VTK headers.
@testset "auto-generated shim accessors and factories" begin
    ug = hex_mesh_with_temperature()
    f = VTK.TableBasedClipDataSet_new()
    VTK.SetInputData(VTK._cp(VTK.vtkAlgorithm, f), VTK._cp(VTK.vtkDataObject, ug))
    p = VTK.plane((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
    VTK.SetClipFunction(VTK._cp(VTK.vtkTableBasedClipDataSet, f),
                        VTK._cp(VTK.vtkImplicitFunction, p))
    # vtkBooleanMacro: On/Off + typed getter
    VTK.InsideOutOn(VTK._cp(VTK.vtkTableBasedClipDataSet, f))
    @test VTK.GetInsideOut(VTK._cp(VTK.vtkTableBasedClipDataSet, f)) == 1
    VTK.InsideOutOff(VTK._cp(VTK.vtkTableBasedClipDataSet, f))
    @test VTK.GetInsideOut(VTK._cp(VTK.vtkTableBasedClipDataSet, f)) == 0
    # vtkBooleanMacro with a C++ bool
    VTK.SetUseValueAsOffset(VTK._cp(VTK.vtkTableBasedClipDataSet, f), true)
    @test VTK.GetUseValueAsOffset(VTK._cp(VTK.vtkTableBasedClipDataSet, f)) == true
    # vtkSetFilePathMacro/vtkGetFilePathMacro on the XML base classes
    mktempdir() do dir
        path = joinpath(dir, "x.vtu")
        w = VTK.XMLUnstructuredGridWriter_new()
        VTK.SetFileName(VTK._cp(VTK.vtkXMLWriterBase, w), path)
        @test VTK.GetFileName(VTK._cp(VTK.vtkXMLWriterBase, w)) == path
    end
    # auto-generated factory for a class without a hand-written one
    pd = VTK.PolyData_new()
    @test VTK.ncells(pd) == 0
    @test VTK.npoints(pd) == 0
end
