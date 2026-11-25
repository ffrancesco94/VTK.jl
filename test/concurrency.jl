using VTK
using Test

@testset "concurrent pipelines with GC pressure" begin
    n = max(16, 4 * Threads.nthreads())
    results = Vector{Any}(undef, n)
    Threads.@threads for i in 1:n
        try
            grid = hex_mesh_with_temperature()
            p = VTK.plane((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
            clipped = VTK.clip(grid, p; insideout=true)
            surf = VTK.contour(grid, [1.5]; scalars="temperature")
            results[i] = (VTK.npoints(clipped), VTK.ncells(clipped), VTK.npoints(surf))
            if isodd(i)
                for _ in 1:20
                    tmp = VTK.data_array(Float64, 3)
                    VTK.resize!(tmp, 8)
                end
                GC.gc(false)
            end
        catch err
            results[i] = err
        end
    end
    for result in results
        result isa Exception && throw(result)
        @test result[1] == 4
        @test result[2] == 1
        @test result[3] > 0
    end

    survivor = VTK.UnstructuredGrid()
    GC.gc(true)
    if Threads.nthreads() > 1
        @test VTK.pending_vtk_deletions() > 0
        @test_throws ArgumentError VTK.drain_vtk_deletions()
        @test VTK.drain_vtk_deletions(force=true) > 0
    else
        @test VTK.drain_vtk_deletions() >= 0
    end
    @test VTK.pending_vtk_deletions() == 0
    @test VTK.npoints(survivor) == 0
end
