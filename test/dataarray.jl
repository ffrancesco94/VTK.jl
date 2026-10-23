using VTK
using Test

@testset "vtkDataArray core" begin
    # typed creation and zero-copy roundtrip
    da = VTK.DoubleArray_new(1)
    VTK.resize!(da, 5)
    @test VTK.ntuples(da) == 5
    @test VTK.ncomponents(da) == 1
    @test size(da) == (1, 5)

    v = VTK.raw_data(da)
    @test eltype(v) == Float64
    @test length(v) == 5
    v[3] = 42.0
    # zero-copy: mutation visible through the VTK component API (0-based)
    @test VTK.GetComponent(VTK._cp(VTK.vtkDataArray, da), 2, 0) == 42.0
    VTK.GetComponent(VTK._cp(VTK.vtkDataArray, da), 2, 0) == 42.0
    VTK.SetComponent(VTK._cp(VTK.vtkDataArray, da), 4, 0, -1.5)
    @test v[5] == -1.5

    # multi-component arrays reshape to (ncomp, ntuples)
    pts = VTK.FloatArray_new(3)
    VTK.resize!(pts, 7)
    @test size(pts) == (3, 7)
    m = VTK.data(pts)
    m[:, 2] = [1.0f0, 2.0f0, 3.0f0]
    @test VTK.GetComponent(VTK._cp(VTK.vtkDataArray, pts), 1, 2) == 3.0f0

    # names
    VTK.name!(da, "temperature")
    @test VTK.name(da) == "temperature"

    # Int arrays are supported with correct element type
    ia = VTK.IntArray_new(1)
    VTK.resize!(ia, 3)
    @test eltype(VTK.raw_data(ia)) == Int32

    # GC stress: dropped references are collected, survivors stay valid
    keep = VTK.DoubleArray_new(1)
    VTK.resize!(keep, 2)
    kd = VTK.raw_data(keep)
    kd[1] = 7.0
    for _ in 1:1000
        tmp = VTK.UnstructuredGrid()
    end
    GC.gc(true)
    @test kd[1] == 7.0
    @test VTK.ntuples(keep) == 2
end
