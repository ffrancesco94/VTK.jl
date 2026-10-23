# dataarray.jl — Julian interface to the vtkDataArray family.
#
# The C++ side exposes a flat zero-copy view of the underlying AOS storage
# (component-fastest), which is column-major for an (ncomponents, ntuples)
# matrix. NOTE: the zero-copy view does not keep the vtkDataArray alive yet —
# keep a reference to the owning dataset/array while using the view.

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
"""
raw_data(da) = zero_copy_data(_cp(vtkDataArray, da))

"""
    data(da) -> Matrix

Zero-copy (ncomponents, ntuples) view of the array storage.
"""
data(da) = reshape(raw_data(da), size(da))

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
