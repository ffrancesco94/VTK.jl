using VTK
using Test

# A unit-cube hex mesh with the linear field T = x + y + z at its points.
function hex_mesh_with_temperature()
    pts = VTK.Points()
    VTK.npoints!(pts, 8)
    coords = [
        (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
        (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
    ]
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

function filter_scalar_array(name, values)
    da = VTK.DoubleArray_new(1)
    VTK.name!(da, name)
    VTK.resize!(da, length(values))
    vec(VTK.data(da)) .= values
    return da
end

function filter_vector_array(name, values)
    da = VTK.DoubleArray_new(size(values, 1))
    VTK.name!(da, name)
    VTK.resize!(da, size(values, 2))
    VTK.data(da) .= values
    return da
end

function filter_field_snapshot(fd)
    return Dict(
        String(name) => copy(vec(VTK.data(VTK.field_array(fd, name))))
            for name in VTK.field_array_names(fd)
    )
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
    @test clipped isa VTK.vtkSmartPointerAllocated{VTK.vtkUnstructuredGrid}
    @test VTK.ncells(clipped) == 1
    @test VTK.npoints(clipped) == 4
    c = VTK.data(VTK.points_array(VTK.points(clipped)))
    @test maximum(c[1, :] .+ c[2, :] .+ c[3, :]) <= 1.0 + 1.0e-12

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
    c2p = VTK.cell_to_point(ugc)
    arr = VTK.field_array(VTK.point_data(c2p), "constant")
    @test all(==(2.5), vec(VTK.data(arr)))

    # point data -> cell data of the linear field averages to 1.5 on the hex
    p2c = VTK.point_to_cell(ug)
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
    @test all(isapprox.(cs[1, :] .+ cs[2, :] .+ cs[3, :], 1.5; atol = 1.0e-8))

    # external surface of the hex
    ext = VTK.extract_surface(ug)
    @test VTK.npoints(ext) == 8

    # calculator: double the temperature field
    calc = VTK.calculator(
        ug; scalars = "temperature",
        expression = "temperature * 2", result = "T2"
    )
    arr = VTK.field_array(VTK.point_data(calc), "T2")
    @test arr !== nothing
    @test vec(VTK.data(arr)) ≈ 2 .* [0, 1, 2, 1, 1, 2, 3, 2]

    # gradient of linear field T = x+y+z is constant (1,1,1)
    grad = VTK.gradient(ug; scalars = "temperature", result = "grad_T")
    @test grad isa VTK.vtkSmartPointerAllocated{VTK.vtkUnstructuredGrid}
    garr = VTK.field_array(VTK.point_data(grad), "grad_T")
    @test garr !== nothing
    gdata = VTK.data(garr)
    @test size(gdata) == (3, 8)
    @test all(isapprox.(gdata[1, :], 1.0; atol = 1.0e-6))
    @test all(isapprox.(gdata[2, :], 1.0; atol = 1.0e-6))
    @test all(isapprox.(gdata[3, :], 1.0; atol = 1.0e-6))

    # threshold: keep cells where all points have T in [1.5, 3.0]
    # The hex has points with T < 1.5, so this should be empty
    thresh = VTK.threshold(ug; scalars = "temperature", lower = 1.5, upper = 3.0)
    @test VTK.ncells(thresh) == 0

    # threshold with wider range should keep the hex
    thresh2 = VTK.threshold(ug; scalars = "temperature", lower = 0.0, upper = 3.0)
    @test VTK.ncells(thresh2) == 1

    # line_source: resolution=N gives N+1 points (N segments)
    line = VTK.line_source((0.0, 0.0, 0.0), (1.0, 1.0, 1.0); resolution = 5)
    @test VTK.npoints(line) == 6

    # sample_over_line: sample temperature along a line
    profile = VTK.sample_over_line(ug, (0.0, 0.0, 0.0), (1.0, 1.0, 1.0); resolution = 5)
    @test VTK.npoints(profile) == 6
    # sampled values should be close to x+y+z along the diagonal
    parr = VTK.field_array(VTK.point_data(profile), "temperature")
    @test parr !== nothing
    @test isapprox(vec(VTK.data(parr)), [0.0, 0.6, 1.2, 1.8, 2.4, 3.0]; atol = 1.0e-6)
    mask = VTK.field_array(VTK.point_data(profile), "vtkValidPointMask")
    @test mask !== nothing
    @test all(==(1), vec(VTK.data(mask)))

    # stream_tracer: vectors= selects VTK's vectors without activating them
    velocity = VTK.data_array(Float64, 3)
    VTK.resize!(velocity, 8)
    for i in 1:8
        velocity[:, i] = [1.0, 0.0, 0.0]
    end
    VTK.name!(velocity, "velocity")
    VTK.add_array!(VTK.point_data(ug), velocity)
    seeds = VTK.line_source((0.5, 0.5, 0.0), (0.5, 0.5, 1.0); resolution = 10)
    stream = VTK.stream_tracer(ug, seeds; vectors = "velocity")
    @test VTK.npoints(stream) == 11

    # GC stress across the full pipeline
    for _ in 1:50
        g = hex_mesh_with_temperature()
        VTK.clip(g, p; insideout = true)
    end
    GC.gc(true)
    @test VTK.npoints(ug) == 8
end

@testset "named filter selection preserves input attributes" begin
    ug = hex_mesh_with_temperature()
    tvals = [0.0, 1.0, 2.0, 1.0, 1.0, 2.0, 3.0, 2.0]
    VTK.add_array!(VTK.point_data(ug), filter_scalar_array("other", 10 .* tvals))
    VTK.add_array!(
        VTK.point_data(ug),
        filter_vector_array("velocity", repeat([1.0, 0.0, 0.0], 1, 8))
    )
    VTK.add_array!(
        VTK.point_data(ug),
        filter_vector_array("cross_velocity", repeat([0.0, 1.0, 0.0], 1, 8))
    )
    VTK.activate_point_data!(ug, "other")
    VTK.SetActiveVectors(VTK.GetPointData(ug), "cross_velocity")
    point_arrays_before = filter_field_snapshot(VTK.point_data(ug))

    # Selection is local to each algorithm; the decoy active scalar is retained.
    surf = VTK.contour(ug, [1.5]; scalars = "temperature")
    cs = VTK.data(VTK.points_array(VTK.points(surf)))
    @test VTK.npoints(surf) > 0
    @test all(isapprox.(cs[1, :] .+ cs[2, :] .+ cs[3, :], 1.5; atol = 1.0e-8))
    @test VTK.name(VTK.GetScalars(VTK.GetPointData(ug))) == "other"

    thresh = VTK.threshold(ug; scalars = "temperature", lower = 0.0, upper = 3.0)
    @test VTK.ncells(thresh) == 1
    @test VTK.name(VTK.GetScalars(VTK.GetPointData(ug))) == "other"

    # The selected x-velocity leaves y fixed even though y-velocity is active.
    seeds = VTK.line_source((0.5, 0.5, 0.0), (0.5, 0.5, 1.0); resolution = 2)
    for direction in ("forward", "backward", "both")
        stream = VTK.stream_tracer(
            ug, seeds; vectors = "velocity",
            integration_direction = direction
        )
        @test VTK.npoints(stream) > 0
        @test VTK.name(VTK.GetVectors(VTK.point_data(ug))) == "cross_velocity"
        if direction == "forward"
            stream_coords = VTK.data(VTK.points_array(VTK.points(stream)))
            @test all(isapprox.(stream_coords[2, :], 0.5; atol = 1.0e-8))
        end
    end
    @test_throws ArgumentError VTK.stream_tracer(
        ug, seeds; vectors = "velocity", integration_direction = "sideways"
    )

    @test VTK.name(VTK.GetScalars(VTK.point_data(ug))) == "other"
    @test VTK.name(VTK.GetVectors(VTK.point_data(ug))) == "cross_velocity"
    @test filter_field_snapshot(VTK.point_data(ug)) == point_arrays_before
end

@testset "sample_over_line scalar allowlist" begin
    ug = hex_mesh_with_temperature()
    tvals = [0.0, 1.0, 2.0, 1.0, 1.0, 2.0, 3.0, 2.0]
    VTK.add_array!(VTK.point_data(ug), filter_scalar_array("other", 2 .* tvals))
    VTK.add_array!(VTK.cell_data(ug), filter_scalar_array("cell_constant", [7.0]))
    VTK.activate_point_data!(ug, "other")
    point_arrays_before = filter_field_snapshot(VTK.point_data(ug))
    cell_arrays_before = filter_field_snapshot(VTK.cell_data(ug))
    has_sampled_array = (output, name) ->
    haskey(VTK.point_data(output), name) || VTK.haskey(VTK.cell_data(output), name)

    profile = VTK.sample_over_line(
        ug, (0.0, 0.0, 0.0), (1.0, 1.0, 1.0);
        resolution = 4, scalars = "temperature"
    )
    @test sort(VTK.field_array_names(VTK.point_data(profile))) ==
        ["temperature", "vtkValidPointMask"]
    @test isapprox(
        vec(VTK.data(VTK.field_array(VTK.point_data(profile), "temperature"))),
        [0.0, 0.75, 1.5, 2.25, 3.0]; atol = 1.0e-6
    )
    @test all(
        ==(1), vec(
            VTK.data(
                VTK.field_array(VTK.point_data(profile), "vtkValidPointMask")
            )
        )
    )
    @test !has_sampled_array(profile, "other")
    @test !has_sampled_array(profile, "cell_constant")

    # Collections retain every requested array while still removing the rest.
    multi = VTK.sample_over_line(
        ug, (0.0, 0.0, 0.0), (1.0, 1.0, 1.0);
        resolution = 2, scalars = ("temperature", "other")
    )
    @test sort(VTK.field_array_names(VTK.point_data(multi))) ==
        ["other", "temperature", "vtkValidPointMask"]
    @test isapprox(
        vec(VTK.data(VTK.field_array(VTK.point_data(multi), "temperature"))),
        [0.0, 1.5, 3.0]; atol = 1.0e-6
    )
    @test isapprox(
        vec(VTK.data(VTK.field_array(VTK.point_data(multi), "other"))),
        [0.0, 3.0, 6.0]; atol = 1.0e-6
    )
    @test !has_sampled_array(multi, "cell_constant")

    # A cell-data-only name is valid, and the validity mask survives filtering.
    cell_only = VTK.sample_over_line(
        ug, (0.0, 0.0, 0.0), (1.0, 1.0, 1.0);
        resolution = 2, scalars = ["cell_constant"]
    )
    @test has_sampled_array(cell_only, "vtkValidPointMask")
    @test !has_sampled_array(cell_only, "temperature")

    # Omitting scalars preserves the existing pass-all behavior.
    pass_all = VTK.sample_over_line(
        ug, (0.0, 0.0, 0.0), (1.0, 1.0, 1.0);
        resolution = 2
    )
    @test has_sampled_array(pass_all, "temperature")
    @test has_sampled_array(pass_all, "other")
    @test has_sampled_array(pass_all, "vtkValidPointMask")

    @test_throws ArgumentError VTK.sample_over_line(
        ug, (0.0, 0.0, 0.0), (1.0, 1.0, 1.0); scalars = "absent"
    )
    @test VTK.name(VTK.GetScalars(VTK.point_data(ug))) == "other"
    @test filter_field_snapshot(VTK.point_data(ug)) == point_arrays_before
    @test filter_field_snapshot(VTK.cell_data(ug)) == cell_arrays_before
end

@testset "gradient and clip concrete output types" begin
    line = VTK.line_source((0.0, 0.0, 0.0), (1.0, 0.0, 0.0); resolution = 2)
    VTK.add_array!(VTK.point_data(line), filter_scalar_array("temperature", [0.0, 0.5, 1.0]))

    grad = VTK.gradient(line; scalars = "temperature")
    @test grad isa VTK.vtkSmartPointerAllocated{VTK.vtkPolyData}
    @test VTK.GetClassName(VTK._cp(VTK.vtkObjectBase, grad)) == "vtkPolyData"
    @test VTK.npoints(grad) == 3

    clipped = VTK.clip(line, VTK.plane((0.25, 0.0, 0.0), (1.0, 0.0, 0.0)))
    @test clipped isa VTK.vtkSmartPointerAllocated{VTK.vtkUnstructuredGrid}
    @test VTK.GetClassName(VTK._cp(VTK.vtkObjectBase, clipped)) == "vtkUnstructuredGrid"
    @test VTK.npoints(clipped) > 0
end

# Auto-generated shim (gen/wrapit/auto_shim.jl): factories and macro
# accessors derived from the VTK headers.
@testset "auto-generated shim accessors and factories" begin
    ug = hex_mesh_with_temperature()
    f = VTK.TableBasedClipDataSet_new()
    VTK.SetInputData(VTK._cp(VTK.vtkAlgorithm, f), VTK._cp(VTK.vtkDataObject, ug))
    p = VTK.plane((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
    VTK.SetClipFunction(
        VTK._cp(VTK.vtkTableBasedClipDataSet, f),
        VTK._cp(VTK.vtkImplicitFunction, p)
    )
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
