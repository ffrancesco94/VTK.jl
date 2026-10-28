# typedarray.jl — parametric typed wrapper around vtkDataArray.
#
# `VTKDataArray{T}` is an AbstractMatrix{T} of shape (ncomponents, ntuples)
# backed by zero-copy views of the VTK array's AOS storage. It holds the
# owning vtkSmartPointer, so the storage stays alive as long as the wrapper
# does, and element access is plain Julia array indexing (type-stable).

# VTK scalar type ids (vtkType.h) -> Julia storage types
const VTK_TO_JULIA_TYPE = Dict{Int,Type}(
    2 => Cchar,    # VTK_CHAR
    15 => Int8,    # VTK_SIGNED_CHAR
    3 => UInt8,    # VTK_UNSIGNED_CHAR
    4 => Int16,    # VTK_SHORT
    5 => UInt16,   # VTK_UNSIGNED_SHORT
    6 => Int32,    # VTK_INT
    7 => UInt32,   # VTK_UNSIGNED_INT
    8 => Clong,    # VTK_LONG
    9 => Culong,   # VTK_UNSIGNED_LONG
    10 => Float32, # VTK_FLOAT
    11 => Float64, # VTK_DOUBLE
    12 => Int64,   # VTK_ID_TYPE
    16 => Int64,   # VTK_LONG_LONG
    17 => UInt64,  # VTK_UNSIGNED_LONG_LONG
)

const JULIA_TO_VTK_TYPE = Dict{Type,Int}(
    Cchar => 2,
    Int8 => 15,
    UInt8 => 3,
    Int16 => 4,
    UInt16 => 5,
    Int32 => 6,
    UInt32 => 7,
    Clong => 8,
    Culong => 9,
    Float32 => 10,
    Float64 => 11,
    Int64 => 16,
    UInt64 => 17,
)

const SP = CxxWrap.CxxWrapCore.SmartPointer

# SmartPointer{vtkDataArray} view of any array smart pointer. The AOS leaf
# types lack CxxWrap's smart-pointer up-cast (their Julia types pre-exist,
# disabling lazy cast registration), so route them through the shim's
# explicit C++-side up-casts.
_as_dataarray_sp(p::SP{vtkDataArray}) = p
_asdataarray_upcast(p) = upcast_dataarray(CxxWrap.CxxWrapCore.ConstCxxRef(p))
_as_dataarray_sp(p::SP{vtkDoubleArray}) = _asdataarray_upcast(p)
_as_dataarray_sp(p::SP{vtkFloatArray}) = _asdataarray_upcast(p)
_as_dataarray_sp(p::SP{vtkIntArray}) = _asdataarray_upcast(p)

"""
    scalar_type(da) -> Type

Julia storage type of a wrapped vtkDataArray (from its VTK type id).
"""
function scalar_type(obj::CxxWrap.CxxWrapCore.SmartPointer{vtkDataArray})
    id = GetDataType(obj)
    haskey(VTK_TO_JULIA_TYPE, id) ||
        throw(ArgumentError("unsupported VTK data type id $id"))
    return VTK_TO_JULIA_TYPE[id]
end

function _typed_view(::Type{T}, obj) where {T}
    ncomp = GetNumberOfComponents(obj)
    nt = GetNumberOfTuples(obj)
    nt == 0 && return Matrix{T}(undef, ncomp, 0)
    return zero_copy_matrix(obj)
end

"""
    VTKDataArray{T} <: AbstractMatrix{T}

Typed, zero-copy view of a VTK data array with `ncomponents` columns and
`ntuples` rows... i.e. `size` is `(ncomponents, ntuples)` (component-fastest,
matching VTK's AOS storage). Construct from any wrapped array object with
`VTKDataArray(obj)` (the element type is discovered from the array), or
create a new array with `data_array(T, ncomponents)`.
"""
mutable struct VTKDataArray{T} <: AbstractMatrix{T}
    obj::CxxWrap.CxxWrapCore.SmartPointer{vtkDataArray}
    view::Matrix{T}

    function VTKDataArray{T}(obj::CxxWrap.CxxWrapCore.SmartPointer) where {T}
        p = _as_dataarray_sp(obj)
        actual = scalar_type(p)
        actual == T || throw(ArgumentError("array stores $actual values, not $T"))
        return new{T}(p, _typed_view(T, p))
    end
end

VTKDataArray(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    VTKDataArray{scalar_type(_as_dataarray_sp(obj))}(obj)

Base.size(a::VTKDataArray) = size(a.view)
Base.getindex(a::VTKDataArray, i::Int, j::Int) = a.view[i, j]
Base.setindex!(a::VTKDataArray{T}, v, i::Int, j::Int) where {T} = (a.view[i, j] = v)

raw_data(a::VTKDataArray) = vec(a)
data(a::VTKDataArray) = a
name(a::VTKDataArray) = name(a.obj)
name!(a::VTKDataArray, s) = name!(a.obj, s)
ntuples(a::VTKDataArray) = size(a.view, 2)
ncomponents(a::VTKDataArray) = size(a.view, 1)
Base.length(a::VTKDataArray) = length(a.view)

# The typed wrapper is accepted anywhere the underlying smart pointer is.
_cp(::Type{T}, a::VTKDataArray) where {T} = _cp(T, a.obj)
add_array!(fd, a::VTKDataArray) = add_array!(fd, a.obj)

Base.Array(a::VTKDataArray{T}) where {T} = Matrix{T}(a.view)

"""
    resize!(a::VTKDataArray, ntuples)

Resize the array. The zero-copy view is refreshed afterwards; previously
obtained views of the same array are invalidated.
"""
function Base.resize!(a::VTKDataArray{T}, n::Integer) where {T}
    SetNumberOfTuples(a.obj, n)
    a.view = _typed_view(T, a.obj)
    return a
end

"""
    data_array(::Type{T}, ncomponents=1) -> VTKDataArray{T}

Create a new VTK data array with element type `T` (e.g. `Float64`) and the
given number of components, initially holding zero tuples.
"""
function data_array(::Type{T}, ncomp::Integer = 1) where {T}
    haskey(JULIA_TO_VTK_TYPE, T) ||
        throw(ArgumentError("no VTK array type for Julia type $T"))
    obj = CreateDataArray(JULIA_TO_VTK_TYPE[T], ncomp)
    return VTKDataArray{T}(obj)
end
