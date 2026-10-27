using VTK
using Test
using WriteVTK

# Multiblock XML I/O (.vtm): a container referencing .vtu/.vtp/... blocks.
# Oracle: WriteVTK.jl writes a multiblock, VTK.jl reads it back; VTK.jl
# writes one and re-reads its own output (ReadVTK.jl has no multiblock
# reader).

@testset "multiblock XML I/O (vtm)" begin
    if !isdefined(VTK, :XMLMultiBlockDataReader_new)
        @info "multiblock XML reader not present (hand-written wrapper) — skipping"
        return
    end

    # Unit hex, reused for both blocks.
    coords = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
        (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
    points = reduce(hcat, [[Float64.(c)...] for c in coords])
    cells = [MeshCell(VTKCellTypes.VTK_HEXAHEDRON, 1:8)]

    mktempdir() do dir
        # WriteVTK writes its multiblock sidecar files relative to the
        # *initial* working directory, so cd into the tempdir and use
        # relative paths for the oracle half.
        cd(dir)

        # ---- read WriteVTK.jl multiblock output (oracle) ----
        vtm = vtk_multiblock("case.vtm")
        b1 = multiblock_add_block(vtm, "fluid")
        vtk_grid(b1, points, cells) do vtk
            vtk["p", VTKPointData()] = collect(0.0:7.0)
        end
        b2 = multiblock_add_block(vtm, "solid")
        vtk_grid(b2, points, cells) do vtk
            vtk["p", VTKPointData()] = collect(10.0:17.0)
        end
        vtk_save(vtm)

        mb = VTK.read_vtm("case.vtm")
        # WriteVTK nests named blocks one level deep: top level holds one
        # sub-block per name, each holding the actual grids.
        @test VTK.nblocks(mb) == 2
        @test VTK.GetClassName(VTK._cp(VTK.vtkObjectBase, mb)) ==
            "vtkMultiBlockDataSet"
        fluid = VTK.block(mb, 1)
        @test VTK.nblocks(fluid) == 1
        g1 = VTK.block(fluid, 1)
        @test g1 isa VTK.vtkSmartPointerAllocated{VTK.vtkUnstructuredGrid}
        @test VTK.npoints(g1) == 8
        @test vec(VTK.data(VTK.field_array(VTK.point_data(g1), "p"))) ≈ 0.0:7.0
        solid = VTK.block(mb, 2)
        g2 = VTK.block(solid, 1)
        @test vec(VTK.data(VTK.field_array(VTK.point_data(g2), "p"))) ≈ 10.0:17.0
        @test_throws BoundsError VTK.block(mb, 3)
        # generic downcast dispatches multiblock too
        @test VTK.downcast(mb) isa VTK.vtkSmartPointerAllocated{VTK.vtkMultiBlockDataSet}

        # ---- write a multiblock with VTK.jl, re-read it ----
        mb2 = VTK.MultiBlockDataSet(2)
        VTK.set_block!(mb2, 1, g1)
        VTK.set_block!(mb2, 2, g2)
        VTK.write_vtm(mb2, "out.vtm")
        @test isfile("out.vtm")
        mb3 = VTK.read_vtm("out.vtm")
        @test VTK.nblocks(mb3) == 2
        g3 = VTK.block(mb3, 1)
        @test vec(VTK.data(VTK.field_array(VTK.point_data(g3), "p"))) ≈ 0.0:7.0
        g4 = VTK.block(mb3, 2)
        @test vec(VTK.data(VTK.field_array(VTK.point_data(g4), "p"))) ≈ 10.0:17.0
    end
end
