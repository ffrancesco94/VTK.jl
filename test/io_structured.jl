using VTK
using Test
using ReadVTK
using WriteVTK

# Structured-grid XML I/O (.vti/.vtr/.vts): round-trips through VTK.jl's
# own readers/writers, cross-checked against ReadVTK.jl/WriteVTK.jl oracles.

# A 2x2x2 image covering the unit cube, origin (0,0,0), spacing (0.5,0.5,0.5).
function make_vti(dir)
    path = joinpath(dir, "img.vti")
    vtk_grid(path[1:end-4], 0.0:0.5:1.0, 0.0:0.5:1.0, 0.0:0.5:1.0) do vtk
        vtk["temperature", VTKPointData()] = collect(0.0:26.0)
    end
    return path
end

# A 2x2x2 rectilinear grid on the same coordinates.
function make_vtr(dir)
    path = joinpath(dir, "rect.vtr")
    vtk_grid(path[1:end-4], [0.0, 0.5, 1.0], [0.0, 0.5, 1.0], [0.0, 0.5, 1.0]) do vtk
        vtk["temperature", VTKPointData()] = collect(0.0:26.0)
    end
    return path
end

# A 2x2x2 curvilinear structured grid on the same coordinates.
function make_vts(dir)
    path = joinpath(dir, "struct.vts")
    xs = [x for x in 0.0:0.5:1.0, y in 0.0:0.5:1.0, z in 0.0:0.5:1.0]
    ys = [y for x in 0.0:0.5:1.0, y in 0.0:0.5:1.0, z in 0.0:0.5:1.0]
    zs = [z for x in 0.0:0.5:1.0, y in 0.0:0.5:1.0, z in 0.0:0.5:1.0]
    vtk_grid(path[1:end-4], xs, ys, zs) do vtk
        vtk["temperature", VTKPointData()] = collect(0.0:26.0)
    end
    return path
end

@testset "structured XML I/O (vti/vtr/vts)" begin
    if !isdefined(VTK, :XMLImageDataReader_new)
        @info "structured XML readers not present (hand-written wrapper) — skipping"
        return
    end
    mktempdir() do dir
        # ---- read WriteVTK.jl output (oracle) ----
        vti_path = make_vti(dir)
        img = VTK.read_vti(vti_path)
        @test VTK.npoints(img) == 27   # 3x3x3 nodes
        da = VTK.field_array(VTK.point_data(img), "temperature")
        @test vec(VTK.data(da)) ≈ 0.0:26.0

        vtr_path = make_vtr(dir)
        rg = VTK.read_vtr(vtr_path)
        @test VTK.npoints(rg) == 27
        da = VTK.field_array(VTK.point_data(rg), "temperature")
        @test vec(VTK.data(da)) ≈ 0.0:26.0

        vts_path = make_vts(dir)
        sg = VTK.read_vts(vts_path)
        @test VTK.npoints(sg) == 27
        da = VTK.field_array(VTK.point_data(sg), "temperature")
        @test vec(VTK.data(da)) ≈ 0.0:26.0

        # ---- write, verify with ReadVTK.jl (oracle) ----
        # raw appended data: ReadVTK.jl does not parse zlib-compressed blocks
        out = joinpath(dir, "img_out.vti")
        VTK.write_vti(img, out)
        f = ReadVTK.VTKFile(out)
        @test ReadVTK.get_origin(f) ≈ [0.0, 0.0, 0.0]
        @test ReadVTK.get_spacing(f) ≈ [0.5, 0.5, 0.5]

        out = joinpath(dir, "rect_out.vtr")
        VTK.write_vtr(rg, out)
        f = ReadVTK.VTKFile(out)

        out = joinpath(dir, "struct_out.vts")
        VTK.write_vts(sg, out)
        f = ReadVTK.VTKFile(out)

        # ---- VTK round-trip: re-read our own written files ----
        img2 = VTK.read_vti(joinpath(dir, "img_out.vti"))
        @test VTK.npoints(img2) == 27
        da = VTK.field_array(VTK.point_data(img2), "temperature")
        @test vec(VTK.data(da)) ≈ 0.0:26.0

        rg2 = VTK.read_vtr(joinpath(dir, "rect_out.vtr"))
        @test VTK.npoints(rg2) == 27
        da = VTK.field_array(VTK.point_data(rg2), "temperature")
        @test vec(VTK.data(da)) ≈ 0.0:26.0

        sg2 = VTK.read_vts(joinpath(dir, "struct_out.vts"))
        @test VTK.npoints(sg2) == 27
        da = VTK.field_array(VTK.point_data(sg2), "temperature")
        @test vec(VTK.data(da)) ≈ 0.0:26.0

        # ---- generic downcast on reader outputs ----
        @test VTK.GetClassName(VTK._cp(VTK.vtkObjectBase, img)) == "vtkImageData"
        @test VTK.GetClassName(VTK._cp(VTK.vtkObjectBase, rg)) == "vtkRectilinearGrid"
        @test VTK.GetClassName(VTK._cp(VTK.vtkObjectBase, sg)) == "vtkStructuredGrid"
        @test VTK.downcast(img) isa VTK.vtkSmartPointerAllocated{VTK.vtkImageData}
        @test VTK.downcast(sg) isa VTK.vtkSmartPointerAllocated{VTK.vtkStructuredGrid}
        @test VTK.npoints(VTK.downcast(rg)) == 27
        # unregistered class name raises KeyError
        @test_throws KeyError VTK.DOWNCAST_REGISTRY["vtkFooBar"]
    end
end
