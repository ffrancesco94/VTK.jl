# Conformance slice for the WrapIt-generated + shim-merged library.
# Run after gen/wrapit/build.jl.  This is the migration CI gate: it replays
# VTK.jl's analytic oracle (clip of a unit hex against x+y+z=1 yields the
# tetrahedron) through the SAME merged library that ships as libvtk_julia.so,
# loaded directly via @wrapmodule (no VTKGen.jl package needed).
#
#   julia --project=gen/wrapit gen/wrapit/conformance.jl
using VTK_jll, Libdl
Libdl.dlopen(VTK_jll.MPICH_jll.libmpi)  # MPI must precede libvtk dlopens
using CxxWrap

const LIB = joinpath(@__DIR__, "build", "shipped", "libvtk_julia.so")
isfile(LIB) ||
    error("merged library not found: $LIB\nRun `julia --project=gen/wrapit gen/wrapit/build.jl` first.")

module Conf
using CxxWrap
const lib = joinpath(@__DIR__, "build", "shipped", "libvtk_julia.so")
@wrapmodule(() -> lib)
function __init__()
    @initcxx
end
end

# raw-pointer conversion, same pattern as the Julian layer (STATUS.md §4.2)
cp(::Type{T}, x) where {T} = CxxWrap.CxxWrapCore.CxxPtr{T}(x[])

# --- build unit-hex mesh with T = x+y+z at points ---
ug = Conf.UnstructuredGrid_new()        # owning factory from the merged shim
pts = Conf.Points_new()
Conf.SetNumberOfPoints(cp(Conf.vtkPoints, pts), 8)
coords = [(0,0,0),(1,0,0),(1,1,0),(0,1,0),(0,0,1),(1,0,1),(1,1,1),(0,1,1)]
for (i, c) in enumerate(coords)
    Conf.SetPoint(cp(Conf.vtkPoints, pts), i - 1, Float64.(c)...)
end
Conf.SetPoints(cp(Conf.vtkPointSet, ug), cp(Conf.vtkPoints, pts))
Conf.Allocate(cp(Conf.vtkUnstructuredGrid, ug), 1)
Conf.InsertNextCell(cp(Conf.vtkUnstructuredGrid, ug), 12,
                     CxxWrap.StdLib.StdVector(Int64.(collect(0:7))))  # VTK_HEXAHEDRON
@assert Conf.GetNumberOfPoints(cp(Conf.vtkPointSet, ug)) == 8 &&
        Conf.GetNumberOfCells(cp(Conf.vtkDataSet, ug)) == 1
println("grid: npts=", Conf.GetNumberOfPoints(cp(Conf.vtkPointSet, ug)),
        " ncells=", Conf.GetNumberOfCells(cp(Conf.vtkDataSet, ug)))

da = Conf.DoubleArray_new(1)            # owning typed factory from the merged shim
Conf.SetNumberOfTuples(cp(Conf.vtkDataArray, da), 8)
unsafe_store!.((convert(Ptr{Float64}, Conf.GetVoidPointer(cp(Conf.vtkDataArray, da), 0)),),
              Float64.(sum.(coords)), 1:8)
Conf.SetArrayName(cp(Conf.vtkDataArray, da), "temperature")  # string-macro accessor
pd = Conf.GetPointData(cp(Conf.vtkDataSet, ug))              # take_ref'd getter
Conf.AddArray(cp(Conf.vtkFieldData, pd), cp(Conf.vtkDataArray, da))
@assert Conf.GetArrayName(cp(Conf.vtkDataArray, da)) == "temperature"
@assert Conf.HasArray(cp(Conf.vtkFieldData, pd), "temperature")
println("temperature attached; name via shim: ",
        Conf.GetArrayName(cp(Conf.vtkDataArray, da)))

# --- clip against plane x+y+z=1, keep the tetrahedron (insideout) ---
plane = Conf.Plane_new()
Conf.SetOrigin(cp(Conf.vtkPlane, plane), 1.0, 0.0, 0.0)
Conf.SetNormal(cp(Conf.vtkPlane, plane), 1.0, 1.0, 1.0)
clip = Conf.TableBasedClipDataSet_new()
Conf.SetInputData(cp(Conf.vtkAlgorithm, clip), cp(Conf.vtkDataObject, ug))
Conf.SetClipFunction(cp(Conf.vtkTableBasedClipDataSet, clip),
                     cp(Conf.vtkImplicitFunction, plane))
Conf.SetInsideOut(cp(Conf.vtkTableBasedClipDataSet, clip), true)  # bool-macro accessor
Conf.Update(cp(Conf.vtkAlgorithm, clip))
out = Conf.downcast_unstructuredgrid(
    cp(Conf.vtkDataObject, Conf.GetOutput(cp(Conf.vtkAlgorithm, clip))))  # owning output
@assert Conf.GetNumberOfPoints(cp(Conf.vtkPointSet, out)) == 4 &&
        Conf.GetNumberOfCells(cp(Conf.vtkDataSet, out)) == 1
println("clip output: npts=", Conf.GetNumberOfPoints(cp(Conf.vtkPointSet, out)),
        " ncells=", Conf.GetNumberOfCells(cp(Conf.vtkDataSet, out)))

# --- write + read back ---
path = joinpath(@__DIR__, "build", "spike_out.vtu")
writer = Conf.XMLUnstructuredGridWriter_new()
Conf.SetInputData(cp(Conf.vtkAlgorithm, writer), cp(Conf.vtkDataObject, out))
Conf.SetFileName(cp(Conf.vtkXMLUnstructuredGridWriter, writer), path)
@assert Conf.Write(cp(Conf.vtkXMLUnstructuredGridWriter, writer)) == 1 && isfile(path)
println("writer returned 1; file exists")

reader = Conf.XMLUnstructuredGridReader_new()
Conf.SetFileName(cp(Conf.vtkXMLUnstructuredGridReader, reader), path)
Conf.Update(cp(Conf.vtkAlgorithm, reader))
ug2 = Conf.downcast_unstructuredgrid(
    cp(Conf.vtkDataObject, Conf.GetOutput(cp(Conf.vtkAlgorithm, reader))))
@assert Conf.GetNumberOfPoints(cp(Conf.vtkPointSet, ug2)) == 4 &&
        Conf.GetNumberOfCells(cp(Conf.vtkDataSet, ug2)) == 1
da2 = Conf.GetArray(cp(Conf.vtkFieldData, Conf.GetPointData(cp(Conf.vtkDataSet, ug2))),
                    "temperature")
vals = unsafe_wrap(Vector{Float64},
                   convert(Ptr{Float64}, Conf.GetVoidPointer(cp(Conf.vtkDataArray, da2), 0)), 4)
@assert vals == [0.0, 1.0, 1.0, 1.0]
println("reader round-trip: npts=", Conf.GetNumberOfPoints(cp(Conf.vtkPointSet, ug2)),
        " ncells=", Conf.GetNumberOfCells(cp(Conf.vtkDataSet, ug2)), " T[1:4]=", vals)
println("CONFORMANCE SLICE PASSED")
