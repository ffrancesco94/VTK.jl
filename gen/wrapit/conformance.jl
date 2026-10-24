# Conformance slice for the WrapIt-generated VTKGen module.
# Run after gen/wrapit/build.jl.  This is the spike's CI gate: it replays
# VTK.jl's analytic oracle (clip of a unit hex against x+y+z=1 yields the
# tetrahedron) entirely through generated bindings + the accessor shim.
#
#   julia --project=gen/wrapit gen/wrapit/conformance.jl
using VTK_jll, Libdl
Libdl.dlopen(VTK_jll.MPICH_jll.libmpi)  # MPI must precede libvtk dlopens
using CxxWrap

const BUILD_DIR = joinpath(@__DIR__, "build")
push!(LOAD_PATH, joinpath(BUILD_DIR, "jl", "src"))
using VTKGen

module VTKGenShim
using CxxWrap, Libdl
@wrapmodule(() -> joinpath(@__DIR__, "build", "jl", "deps",
                           "libjlVTKGenShim." * Libdl.dlext))
__init__() = @initcxx
end
using .VTKGenShim

New(T::Symbol) = getproperty(VTKGen, Symbol("vtk$(T)!New"))()

# --- build unit-hex mesh with T = x+y+z at points ---
ug = New(:UnstructuredGrid)
pts = New(:Points)
SetNumberOfPoints(pts, 8)
coords = [(0,0,0),(1,0,0),(1,1,0),(0,1,0),(0,0,1),(1,0,1),(1,1,1),(0,1,1)]
for (i, c) in enumerate(coords); SetPoint(pts, i - 1, Float64.(c)...); end
SetPoints(ug, pts)
Allocate(ug, 1)
ids = New(:IdList); [InsertNextId(ids, i) for i in 0:7]
InsertNextCell(ug, 12, ids)  # VTK_HEXAHEDRON
@assert GetNumberOfPoints(ug) == 8 && GetNumberOfCells(ug) == 1
println("grid: npts=", GetNumberOfPoints(ug), " ncells=", GetNumberOfCells(ug))

da = New(:DoubleArray)
SetNumberOfTuples(da, 8)
unsafe_store!.((convert(Ptr{Float64}, GetVoidPointer(da, 0)),),
               Float64.(sum.(coords)), 1:8)
VTKGenShim.shimSetName(da, "temperature")
pd = GetPointData(ug)
AddArray(pd, da)
@assert VTKGenShim.shimGetName(da) == "temperature"
@assert GetArray(pd, 0) !== nothing
println("temperature attached; name via shim: ", VTKGenShim.shimGetName(da))

# --- clip against plane x+y+z=1, keep the tetrahedron (insideout) ---
plane = New(:Plane)
SetOrigin(plane, 1.0, 0.0, 0.0)
SetNormal(plane, 1.0, 1.0, 1.0)
clip = New(:TableBasedClipDataSet)
SetInputDataObject(clip, ug)
SetClipFunction(clip, plane)
VTKGenShim.shimSetInsideOut(clip, true)
Update(clip)
out = GetOutput(clip)
@assert GetNumberOfPoints(out) == 4 && GetNumberOfCells(out) == 1
println("clip output: npts=", GetNumberOfPoints(out), " ncells=", GetNumberOfCells(out))

# --- write + read back ---
path = joinpath(BUILD_DIR, "spike_out.vtu")
writer = New(:XMLUnstructuredGridWriter)
SetInputDataObject(writer, out)
VTKGenShim.shimSetFileName(writer, path)
@assert Write(writer) == 1 && isfile(path)
println("writer returned 1; file exists")

reader = New(:XMLUnstructuredGridReader)
VTKGenShim.shimSetReaderFileName(reader, path)
Update(reader)
ug2 = GetOutput(reader)
@assert GetNumberOfPoints(ug2) == 4 && GetNumberOfCells(ug2) == 1
da2 = GetArray(GetPointData(ug2), 0)
vals = unsafe_wrap(Vector{Float64}, convert(Ptr{Float64}, GetVoidPointer(da2, 0)), 4)
@assert vals == [0.0, 1.0, 1.0, 1.0]
println("reader round-trip: npts=", GetNumberOfPoints(ug2),
        " ncells=", GetNumberOfCells(ug2), " T[1:4]=", vals)
println("CONFORMANCE SLICE PASSED")
