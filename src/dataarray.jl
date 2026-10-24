# dataarray.jl — Julian interface to the vtkDataArray family.
#
# The C++ side exposes a zero-copy view of the underlying AOS storage at the
# target dimensionality (flat vector or (ncomponents, ntuples) matrix),
# created directly as plain jl_array_t. Component-fastest layout is exactly
# column-major for the matrix shape.
#
# Ownership: views do NOT own the vtkDataArray — they are valid only while
# the owning smart pointer/dataset is alive (see §4 of STATUS.md). Do NOT
# attach owner-capturing finalizers to views: empirical testing showed that
# destroying VTK C++ objects from GC finalizer threads corrupts concurrently
# running VTK pipelines (heisenbug failures under multi-threaded GC).

# Convert a wrapped object (smart pointer) to a raw C++ pointer of the
# requested static type, for calling low-level methods that take T*.
_cp(::Type{T}, x) where {T} = CxxPtr{T}(x[])

ntuples(da) = GetNumberOfTuples(_cp(vtkDataArray, da))
ncomponents(da) = GetNumberOfComponents(_cp(vtkDataArray, da))

Base.size(da) = (ncomponents(da), ntuples(da))
Base.length(da) = ncomponents(da) * ntuples(da)

"""
    raw_data(da) -> Vector

Zero-copy flat view of the array storage (component-fastest, length
`ncomponents * ntuples`). The element type matches the array's storage type.
The view borrows the storage: keep `da` (or the owning dataset) alive while
using it.
"""
raw_data(da::CxxWrap.CxxWrapCore.SmartPointer) = zero_copy_data(_cp(vtkDataArray, da))

"""
    data(da) -> Matrix

Zero-copy (ncomponents, ntuples) view of the array storage. Borrows the
storage: keep `da` (or the owning dataset) alive while using it.
"""
data(da::CxxWrap.CxxWrapCore.SmartPointer) = zero_copy_matrix(_cp(vtkDataArray, da))

name(da) = GetArrayName(_cp(vtkDataArray, da))
name!(da, s) = SetArrayName(_cp(vtkDataArray, da), String(s))

"""
    resize!(da, ntuples)

Set the number of tuples. Call before writing through a `data`/`raw_data` view.
"""
function Base.resize!(da::CxxWrap.CxxWrapCore.SmartPointer{<:vtkDataArray}, n::Integer)
    SetNumberOfTuples(_cp(vtkDataArray, da), n)
    return da
end
