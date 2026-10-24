using VTK
using Test

@testset "VTKDataArray{T} typed wrapper" begin
    # typed factory, resize, indexing, zero-copy visibility
    a = VTK.data_array(Float64, 3)
    @test eltype(a) == Float64
    @test size(a) == (3, 0)
    VTK.resize!(a, 4)
    @test size(a) == (3, 4)
    a[:, 2] = [1.0, 2.0, 3.0]
    @test a[2, 2] == 2.0
    @test vec(a[:, 2]) == [1.0, 2.0, 3.0]
    # writes through to the VTK storage
    @test VTK.GetComponent(VTK._cp(VTK.vtkDataArray, a.obj), 1, 2) == 3.0

    # type-stable indexing
    @inferred a[1, 1]
    @inferred eltype(a)

    # setindex! is visible through the typed view (component 3 1-based -> 0-based index 2)
    a[3, 4] = -7.5
    @test VTK.GetComponent(VTK._cp(VTK.vtkDataArray, a.obj), 3, 2) == -7.5

    # type mismatches are rejected
    @test_throws ArgumentError VTK.VTKDataArray{Float32}(a.obj)

    # discovery from an untyped factory smart pointer
    sp = VTK.FloatArray_new(2)
    VTK.resize!(sp, 3)
    ta = VTK.VTKDataArray(sp)
    @test eltype(ta) == Float32
    @test size(ta) == (2, 3)

    # all common CFD scalar types
    for T in (Float32, Float64, Int32, Int64, UInt8)
        arr = VTK.data_array(T)
        VTK.resize!(arr, 2)
        arr[1, 2] = T == UInt8 ? 0x2a : T(42)
        @test arr[1, 2] == (T == UInt8 ? 0x2a : T(42))
    end

    # resize refreshes the view; values survive reallocation. The grown
    # region is NOT zero-initialized by VTK, so zero it explicitly before
    # summing (a heap-dependent NaN/garbage flake otherwise).
    VTK.resize!(a, 6)
    a[:, 1] .= 0
    a[:, 3] .= 0
    a[:, 5] .= 0
    a[2:3, 6] .= 0
    @test size(a) == (3, 6)
    a[1, 6] = 99.0
    @test a[1, 6] == 99.0
    @test sum(a) ≈ 1.0 + 2.0 + 3.0 - 7.5 + 99.0

    # field_array returns the typed wrapper
    ug = VTK.UnstructuredGrid()
    pts = VTK.Points()
    VTK.npoints!(pts, 2)
    pts[1] = (0.0, 0.0, 0.0)
    pts[2] = (1.0, 0.0, 0.0)
    VTK.set_points!(ug, pts)
    VTK.allocate!(ug, 1)
    VTK.insert_cell!(ug, VTK.VTK_HEXAHEDRON, [0, 0, 0, 0, 1, 1, 1, 1])
    da = VTK.data_array(Float64, 1)
    VTK.name!(da, "p")
    VTK.resize!(da, 2)
    da[1, 1] = 3.25
    da[1, 2] = 6.5
    VTK.add_array!(VTK.point_data(ug), da.obj)
    p = VTK.field_array(VTK.point_data(ug), "p")
    @test p isa VTK.VTKDataArray{Float64}
    @test p[1, 2] == 6.5
    p[1, 2] = -1.0
    @test da[1, 2] == -1.0
    @test VTK.field_array(VTK.point_data(ug), "missing") === nothing

    # GC stress: views survive collection of other objects
    keep = VTK.data_array(Float64, 1)
    VTK.resize!(keep, 3)
    keep[1, 2] = 123.0
    for _ in 1:1000
        tmp = VTK.data_array(Float64, 1)
        VTK.resize!(tmp, 4)
    end
    GC.gc(true)
    @test keep[1, 2] == 123.0
end
