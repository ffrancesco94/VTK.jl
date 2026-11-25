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
    try
        return zero_copy_matrix(obj)
    catch exception
        exception isa InterruptException && rethrow()
        throw(VTKUnsupportedTypeError(GetClassName(obj)))
    end
end

"""
    VTKDataArray{T} <: AbstractMatrix{T}

Typed, zero-copy view of a VTK data array whose `size` is
`(ncomponents, ntuples)` (component-fastest, matching VTK's AOS storage).
Construct from any wrapped array object with `VTKDataArray(obj)` (the element
type is discovered from the array), or create a new array with
`data_array(T, ncomponents)`.
"""
mutable struct VTKDataArray{T} <: AbstractMatrix{T}
    obj::CxxWrap.CxxWrapCore.SmartPointer{vtkDataArray}
    view::Matrix{T}
    mtime::UInt64
    data_pointer::Ptr{Nothing}

    function VTKDataArray{T}(obj::CxxWrap.CxxWrapCore.SmartPointer) where {T}
        p = _as_dataarray_sp(obj)
        actual = scalar_type(p)
        actual == T || throw(ArgumentError("array stores $actual values, not $T"))
        return new{T}(p, _typed_view(T, p), GetMTime(p), GetVoidPointer(p, 0))
    end
end

VTKDataArray(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    VTKDataArray{scalar_type(_as_dataarray_sp(obj))}(obj)

"""
    refresh!(a::VTKDataArray)

Rebuild the cached zero-copy view from the underlying VTK array and record
its current structural signature. Array operations do this automatically when
the modification time, dimensions, or data-buffer address change; call
`refresh!` directly only when explicit control is needed. Independently
obtained views of an old buffer remain invalid after reallocation.
"""
function refresh!(a::VTKDataArray{T}) where {T}
    a.view = _typed_view(T, a.obj)
    a.mtime = GetMTime(a.obj)
    a.data_pointer = GetVoidPointer(a.obj, 0)
    return a
end

function _sync!(a::VTKDataArray)
    # SetNumberOfTuples does not necessarily call Modified in VTK, so MTime
    # alone cannot detect a resize. Check the shape and buffer address too;
    # the latter also catches reallocation that restores the original shape.
    unchanged = GetMTime(a.obj) == a.mtime &&
        GetNumberOfComponents(a.obj) == size(a.view, 1) &&
        GetNumberOfTuples(a.obj) == size(a.view, 2) &&
        GetVoidPointer(a.obj, 0) == a.data_pointer
    unchanged || refresh!(a)
    return nothing
end

function Base.size(a::VTKDataArray)
    _sync!(a)
    return size(a.view)
end

function Base.getindex(a::VTKDataArray, i::Int, j::Int)
    _sync!(a)
    return a.view[i, j]
end

function Base.setindex!(a::VTKDataArray, v, i::Int, j::Int)
    _sync!(a)
    a.view[i, j] = v
end

function raw_data(a::VTKDataArray)
    _sync!(a)
    return vec(a)
end

data(a::VTKDataArray) = a
name(a::VTKDataArray) = name(a.obj)
name!(a::VTKDataArray, s) = name!(a.obj, s)

function ntuples(a::VTKDataArray)
    _sync!(a)
    return size(a.view, 2)
end

function ncomponents(a::VTKDataArray)
    _sync!(a)
    return size(a.view, 1)
end

function Base.length(a::VTKDataArray)
    _sync!(a)
    return length(a.view)
end

# The typed wrapper is accepted anywhere the underlying smart pointer is.
_cp(::Type{T}, a::VTKDataArray) where {T} = _cp(T, a.obj)
add_array!(fd, a::VTKDataArray) = add_array!(fd, a.obj)

function Base.Array(a::VTKDataArray{T}) where {T}
    _sync!(a)
    return Matrix{T}(a.view)
end

"""
    resize!(a::VTKDataArray, ntuples)

Resize the array to a nonnegative number of tuples and refresh its zero-copy
view. Other `VTKDataArray` wrappers of the same VTK object refresh on their
next array operation. Previously obtained independent views are invalidated
by reallocation, and newly grown storage is uninitialized.
"""
function Base.resize!(a::VTKDataArray, n::Integer)
    n >= 0 || throw(ArgumentError("number of tuples must be nonnegative, got $n"))
    SetNumberOfTuples(a.obj, n)
    refresh!(a)
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
    ncomp >= 1 || throw(ArgumentError(
        "number of components must be positive, got $ncomp"))
    _drain_vtk_deletions_if_serial()
    obj = CreateDataArray(JULIA_TO_VTK_TYPE[T], ncomp)
    return VTKDataArray{T}(obj)
end
