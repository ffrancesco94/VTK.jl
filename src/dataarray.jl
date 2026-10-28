# dataarray.jl — Julian interface to the vtkDataArray family.
#
# The C++ side exposes a zero-copy view of the underlying AOS storage at the
# target dimensionality (flat vector or (ncomponents, ntuples) matrix),
# created directly as plain jl_array_t. Component-fastest layout is exactly
# column-major for the matrix shape.
#
# Ownership: this module hands out OWNING handles. `data` returns a
# VTKDataArray wrapper (holds the smart pointer as a field); `raw_data`
# returns a flat view derived from that wrapper. The derivation chain
# (ReshapedArray -> VTKDataArray -> SmartPointer) keeps the C++ object
# alive structurally — no finalizers are attached to views (see §4.1 of
# STATUS.md: C++ VTK objects must not be destroyed from GC finalizer
# threads). Dropping all references releases through CxxWrap's standard
# SmartPointer finalizer, the baseline behavior this package has always had.

# Convert a wrapped object (smart pointer) to a raw C++ pointer of the
# requested static type, for calling low-level methods that take T*.
_cp(::Type{T}, x) where {T} = CxxPtr{T}(x[])

ntuples(da) = GetNumberOfTuples(da)
ncomponents(da) = GetNumberOfComponents(da)

Base.size(da) = (ncomponents(da), ntuples(da))
Base.length(da) = ncomponents(da) * ntuples(da)

"""
    raw_data(da) -> AbstractVector

Zero-copy flat view of the array storage (component-fastest, length
`ncomponents * ntuples`). The element type matches the array's storage type.
The view is derived from an owning `VTKDataArray` wrapper, so the underlying
storage stays alive as long as the view does — the owner may be dropped.
"""
raw_data(da::CxxWrap.CxxWrapCore.SmartPointer) = vec(VTKDataArray(da))

"""
    data(da) -> VTKDataArray{T}

Owning, typed, zero-copy `(ncomponents, ntuples)` view of the array storage.
Holds the underlying smart pointer, so it (and views derived from it, e.g.
`vec`) stay valid after the original handle is dropped.
"""
data(da::CxxWrap.CxxWrapCore.SmartPointer) = VTKDataArray(da)

name(da) = GetArrayName(da)
name!(da, s) = SetArrayName(da, String(s))

"""
    resize!(da, ntuples)

Set the number of tuples. Call before writing through a `data`/`raw_data` view.
"""
function Base.resize!(da::CxxWrap.CxxWrapCore.SmartPointer{<:vtkDataArray}, n::Integer)
    SetNumberOfTuples(da, n)
    return da
end
