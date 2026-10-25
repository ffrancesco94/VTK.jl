# Conformance slice for the WrapIt-generated + shim-merged VTKGen module.
# Run after gen/wrapit/build.jl.  This is the migration CI gate: it replays
# VTK.jl's analytic oracle (clip of a unit hex against x+y+z=1 yields the
# tetrahedron) through the SAME merged library that ships as libvtk_julia.so
# (ownership factories, macro-accessor shims, and generated bindings).
#
#   julia --project=gen/wrapit gen/wrapit/conformance.jl
using VTK_jll, Libdl
Libdl.dlopen(VTK_jll.MPICH_jll.libmpi)  # MPI must precede libvtk dlopens
using CxxWrap

const BUILD_DIR = joinpath(@__DIR__, "build")
push!(LOAD_PATH, joinpath(BUILD_DIR, "jl", "src"))
using VTKGen

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
InsertNextCell(ug, 12, ids)  # VTK_HEXAHEDRON (via the merged shim's vector overload)
@assert GetNumberOfPoints(ug) == 8 && GetNumberOfCells(ug) == 1
println("grid: npts=", GetNumberOfPoints(ug), " ncells=", GetNumberOfCells(ug))

da = New(:DoubleArray)
SetNumberOfTuples(da, 8)
unsafe_store!.((convert(Ptr{Float64}, GetVoidPointer(da, 0)),),
               Float64.(sum.(coords)), 1:8)
SetArrayName(da, "temperature")       # string-macro accessor from the merged shim
pd = GetPointData(ug)                 # take_ref'd getter from the merged shim
AddArray(pd, da)
@assert GetArrayName(da) == "temperature"
@assert GetArray(pd, 0) !== nothing
println("temperature attached; name via shim: ", GetArrayName(da))

# --- clip against plane x+y+z=1, keep the tetrahedron (insideout) ---
plane = New(:Plane)
SetOrigin(plane, 1.0, 0.0, 0.0)
SetNormal(plane, 1.0, 1.0, 1.0)
clip = New(:TableBasedClipDataSet)
SetInputData(clip, ug)                # per-filter convenience from the merged shim
SetClipFunction(clip, plane)
SetInsideOut(clip, true)              # boolean-macro accessor from the merged shim
Update(clip)
out = GetOutput(clip)                 # owning take_ref'd output from the merged shim
@assert GetNumberOfPoints(out) == 4 && GetNumberOfCells(out) == 1
println("clip output: npts=", GetNumberOfPoints(out), " ncells=", GetNumberOfCells(out))

# --- write + read back ---
path = joinpath(BUILD_DIR, "spike_out.vtu")
writer = New(:XMLUnstructuredGridWriter)
SetInputData(writer, out)
SetFileName(writer, path)
@assert Write(writer) == 1 && isfile(path)
println("writer returned 1; file exists")

reader = New(:XMLUnstructuredGridReader)
SetFileName(reader, path)
Update(reader)
ug2 = GetOutput(reader)
@assert GetNumberOfPoints(ug2) == 4 && GetNumberOfCells(ug2) == 1
da2 = GetArray(GetPointData(ug2), 0)
vals = unsafe_wrap(Vector{Float64}, convert(Ptr{Float64}, GetVoidPointer(da2, 0)), 4)
@assert vals == [0.0, 1.0, 1.0, 1.0]
println("reader round-trip: npts=", GetNumberOfPoints(ug2),
        " ncells=", GetNumberOfCells(ug2), " T[1:4]=", vals)
println("CONFORMANCE SLICE PASSED")
