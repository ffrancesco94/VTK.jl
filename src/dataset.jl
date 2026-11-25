# dataset.jl — grid construction, field data access

const VTKDataObjectHandle = Union{
    CxxWrap.CxxWrapCore.SmartPointer,
    CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject},
}

function _forced_downcast(obj, expected, fn)
    try
        return fn(obj)
    catch exception
        actual = if obj isa CxxWrap.CxxWrapCore.CxxPtr && obj.cpp_object == C_NULL
            "null"
        else
            try
                GetClassName(obj)
            catch
                "invalid VTK object"
            end
        end
        throw(VTKTypeError(expected, actual))
    end
end

function UnstructuredGrid()
    _drain_vtk_deletions_if_serial()
    return UnstructuredGrid_new()
end
UnstructuredGrid(obj::VTKDataObjectHandle) = _forced_downcast(
    obj, "vtkUnstructuredGrid", downcast_unstructuredgrid
)
PolyData(obj::VTKDataObjectHandle) = _forced_downcast(
    obj, "vtkPolyData", downcast_polydata
)
ImageData(obj::VTKDataObjectHandle) = _forced_downcast(
    obj, "vtkImageData", downcast_imagedata
)
RectilinearGrid(obj::VTKDataObjectHandle) = _forced_downcast(
    obj, "vtkRectilinearGrid", downcast_rectilineargrid
)
StructuredGrid(obj::VTKDataObjectHandle) = _forced_downcast(
    obj, "vtkStructuredGrid", downcast_structuredgrid
)
MultiBlockDataSet(obj::VTKDataObjectHandle) = _forced_downcast(
    obj, "vtkMultiBlockDataSet", downcast_multiblock
)
function Points()
    _drain_vtk_deletions_if_serial()
    return Points_new()
end

# ---- generic hierarchy-aware downcast --------------------------------------
# DOWNCAST_REGISTRY maps exact VTK class names to typed constructors. The
# IsA fallback handles derived classes; unknown data objects remain available
# through an owning vtkDataObject handle instead of failing with KeyError.
const DOWNCAST_SOURCES = [
    (:vtkUnstructuredGrid, "vtkUnstructuredGrid", :downcast_unstructuredgrid),
    (:vtkPolyData, "vtkPolyData", :downcast_polydata),
    (:vtkImageData, "vtkImageData", :downcast_imagedata),
    (:vtkRectilinearGrid, "vtkRectilinearGrid", :downcast_rectilineargrid),
    (:vtkStructuredGrid, "vtkStructuredGrid", :downcast_structuredgrid),
    (:vtkMultiBlockDataSet, "vtkMultiBlockDataSet", :downcast_multiblock),
]

const DOWNCAST_REGISTRY = Dict{String, Function}()

function _init_downcast_registry!()
    for (Tname, name, fn) in DOWNCAST_SOURCES
        isdefined(@__MODULE__, Tname) || continue   # type not in this library
        isdefined(@__MODULE__, fn) || continue      # no downcast binding
        DOWNCAST_REGISTRY[name] = obj -> getfield(@__MODULE__, fn)(obj)
    end
    return nothing
end

"""
    downcast(obj) -> typed grid or vtkDataObject

Recover the nearest registered grid type from a generic `vtkDataObject`.
Derived VTK classes are recognized through `IsA`. An unregistered class is
returned as an owning generic `vtkDataObject` handle. Null objects and invalid
forced downcasts are errors; a non-null dataset with zero points/cells is not.
"""
function downcast(obj::VTKDataObjectHandle)
    owned = try
        TakeRefDataObject(_cp(vtkDataObject, obj))
    catch
        actual = obj isa CxxWrap.CxxWrapCore.CxxPtr && obj.cpp_object == C_NULL ?
            "null" : "invalid VTK object"
        throw(VTKTypeError("non-null vtkDataObject", actual))
    end
    name = GetClassName(owned)
    haskey(DOWNCAST_REGISTRY, name) && return DOWNCAST_REGISTRY[name](owned)
    for (_, base_name, fn) in DOWNCAST_SOURCES
        isdefined(@__MODULE__, fn) || continue
        IsA(owned, base_name) != 0 || continue
        return getfield(@__MODULE__, fn)(owned)
    end
    return owned
end

const VTK_HEXAHEDRON = 12
const VTK_TETRA = 10

# Fixed arities for the standard linear and quadratic cells. Variable-size
# cells have a minimum arity instead. Other cell families need a dedicated
# connectivity representation and are rejected rather than passed blindly to
# vtkUnstructuredGrid::InsertNextCell.
const VTK_FIXED_CELL_ARITY = Dict{Int, Int}(
    0 => 0, 1 => 1, 3 => 2, 5 => 3, 8 => 4, 9 => 4,
    10 => 4, 11 => 8, 12 => 8, 13 => 6, 14 => 5, 15 => 10, 16 => 12,
    21 => 3, 22 => 6, 23 => 8, 24 => 10, 25 => 20, 26 => 15,
    27 => 13, 28 => 9, 29 => 27, 30 => 6, 31 => 12, 32 => 18,
    33 => 24, 34 => 7, 35 => 4,
)
const VTK_VARIABLE_CELL_MIN_ARITY = Dict{Int, Int}(
    2 => 1, 4 => 2, 6 => 3, 7 => 3, 36 => 3,
)

function _validate_cell(celltype::Int, ids, np::Integer)
    if haskey(VTK_FIXED_CELL_ARITY, celltype)
        expected = VTK_FIXED_CELL_ARITY[celltype]
        length(ids) == expected || throw(
            ArgumentError(
                "VTK cell type $celltype requires $expected point ids, got $(length(ids))"
            )
        )
    elseif haskey(VTK_VARIABLE_CELL_MIN_ARITY, celltype)
        minimum = VTK_VARIABLE_CELL_MIN_ARITY[celltype]
        length(ids) >= minimum || throw(
            ArgumentError(
                "VTK cell type $celltype requires at least $minimum point ids, got $(length(ids))"
            )
        )
    else
        throw(ArgumentError("unsupported VTK cell type $celltype"))
    end
    all(id -> id isa Integer, ids) ||
        throw(ArgumentError("cell point ids must be integers"))
    for id in ids
        0 <= id < np || throw(
            ArgumentError(
                "cell point id $id is outside the valid 0-based range 0:$(np - 1)"
            )
        )
    end
    return nothing
end

"""
    insert_cell!(grid, celltype, point_ids)

Insert a cell of `celltype` (e.g. `VTK_HEXAHEDRON`) referencing 0-based
integer `point_ids`. Connectivity and cell arity are validated before VTK is
called.
"""
function insert_cell!(
        grid::VTKSmartPointer{<:vtkUnstructuredGrid},
        celltype::Integer, point_ids
    )
    ids = collect(point_ids)
    _validate_cell(Int(celltype), ids, npoints(grid))
    native_ids = CxxWrap.StdLib.StdVector(Int64.(ids))
    InsertNextCell(grid, celltype, native_ids)
    return grid
end

function Base.setindex!(pts::VTKSmartPointer{<:vtkPoints}, coord, i::Integer)
    1 <= i <= npoints(pts) || throw(BoundsError(pts, i))
    values = Tuple(coord)
    length(values) == 3 || throw(
        ArgumentError(
            "a point needs exactly three coordinates, got $(length(values))"
        )
    )
    all(x -> x isa Real, values) ||
        throw(ArgumentError("point coordinates must be real numbers"))
    SetPoint(pts, i - 1, values...)
    return pts
end

function npoints!(pts::VTKSmartPointer{<:vtkPoints}, n::Integer)
    n >= 0 || throw(ArgumentError("number of points must be nonnegative, got $n"))
    SetNumberOfPoints(pts, n)
    return pts
end

set_points!(grid, pts) = SetPoints(grid, pts)

function allocate!(grid::VTKSmartPointer{<:vtkUnstructuredGrid}, n::Integer)
    n >= 0 || throw(ArgumentError("cell allocation must be nonnegative, got $n"))
    Allocate(grid, n)
    return grid
end

function point_coordinates(grid, i::Integer)
    1 <= i <= npoints(grid) || throw(BoundsError(grid, i))
    return GetPointCoordinates(grid, i - 1)
end

ncells(grid) = GetNumberOfCells(grid)
npoints(grid) = GetNumberOfPoints(grid)
npoints(pts::VTKSmartPointer{<:vtkPoints}) = ntuples(GetPointData(pts))

"""
    points(grid) -> vtkPoints (owning reference)

The points object of a point set.
"""
points(grid) = GetPoints(grid)

"""
    points_array(pts) -> VTKDataArray{T}

The coordinate array of a vtkPoints object (3 components).
"""
function points_array(pts)
    array = VTKDataArray(GetPointData(pts))
    ncomponents(array) == 3 || throw(
        ArgumentError(
            "point coordinates must have three components, got $(ncomponents(array))"
        )
    )
    return array
end

# We get our cell_data and point_data wrappers to use a DataAssociation struct to have visibility into the owning dataset
"""
    DataAssociation 

Internal owner-aware view of a dataset's point or cell data. 
The users can obtain it through `point_data(grid)` or `cell_data(grid)`. 
"""
struct DataAssociation{H, D} <: AbstractDict{String, Any}
    handle::H
    dataset::D
    kind::Symbol
end

_point_data_handle(grid) = GetPointData(grid)
_cell_data_handle(grid) = GetCellData(grid)

function _association_view(grid::VTKSmartPointer{<:vtkDataSet}, association::Symbol)
    association === :point && return DataAssociation(GetPointData(grid), grid, :point)
    associaation === :cell && return (GetCellData(grid), grid, :cell)

    throw(ArgumentError("Association must be :point or :cell"))
end

"""
    point_data(grid) -> DataAssociation

Dictionary-like access to the grid's point-associated arrays. Ordinary Julia
arrays into this association are copied. Existing VTK arrays are attached
without another copy. 
"""
point_data(grid::VTKSmartPointer{<:vtkDataSet}) = _association_view(grid, :point)

"""
    cell_data(grid) -> DataAssociation 

Dictionary-like access to the grid's cell-associated arrays.  Ordinary Julia
arrays into this association are copied. Existing VTK arrays are attached
without another copy. 
"""
cell_data(grid::VTKSmartPointer{<:vtkDataSet}) = _association_view(grid, :cell)

# Base overrides needed for dictionary-like access

Base.length(data::DataAssociation) = Int(GetNumberOfArrays(data.handle))
Base.haskey(data::DataAssociation, name::AbstractString) = HasArray(data.handle, String(name))

function Base.keys(data::DataAssociation)
    return [
        String(GetArrayNameOf(data.handle, i)) for i in 0:(length(data) - 1)
    ]
end

function Base.getindex(data::DataAssociation, name::AbstractString)
    haskey(data, name) || throw(KeyError(String(name)))
    return field_array(data.handle, name)
end

function Base.iterate(data::DataAssociation, state::Int = 0)
    state >= length(data) && return nothing

    name = String(GetArrayNameOf(data.handle, state))
    return (name => data[name]), state + 1
end

function Base.delete!(data::DataAssociation, name::AbstractString)
    haskey(data, name) || return data
    RemoveArray(data.handle, String(name))
    return data
end

# Make sure nothing breaks with existing Julian helpers

field_array(data::DataAssociation, name) = haskey(data, name) ? field_array(data.handle, name) : nothing

field_array_raw(data::DataAssociation, name) = haskey(data, name) ? field_array_raw(data.handle, name) : nothing

field_array_names(data::DataAssociation) = keys(data)

field_array_names(fd) =
    [GetArrayNameOf(fd, i) for i in 0:(GetNumberOfArrays(fd) - 1)]

function _numeric_field_array(fd, name)
    abstract_array = GetAbstractArray(fd, String(name))
    IsA(abstract, "vtkDataArray") != 0 || throw(VTKUnsupportedTypeError(GetClassName(abstract_array)))
    return GetArray(fd, String(name))
end

"""
    field_array(fd, name) -> VTKDataArray{T} or nothing

Typed zero-copy view of the named array in field data `fd`.
"""
function field_array(fd, name)
    HasArray(fd, String(name)) || return nothing
    return VTKDataArray(_numeric_field_array(fd, name))
end

"""
    field_array_raw(fd, name) -> vtkDataArray smart pointer or nothing

Untyped variant of `field_array`.
"""
function field_array_raw(fd, name)
    HasArray(fd, String(name)) || return nothing
    return _numeric_field_array(fd, name)
end

function add_array!(fd, da)
    AddArray(fd, da)
    return da
end

# ---- shared assignment ----

_assignment_array(values::VTKDataArray) = values
_assignment_array(values::VTKSmartPointer{<:vtkDataArray}) = VTKDataArray(values)
_assignment_array(values::AbstractArray) = data_array(values)
_assignment_array(values) = throw(ArgumentError("Field assignments expects an AbstractArray or VTKDataArray. Got $(typeof(values))"))

# TODO: implement set_array!()

"""
    remove_array!(grid, name; point=true, cell=true)

Remove the named array from point data, cell data, or both. Searches point
data first, then cell data. Throws an error if the array is not found.
"""
function remove_array!(grid, name; point = true, cell = true)
    point || cell || throw(ArgumentError("at least one of point or cell must be true"))
    name = String(name)
    removed = false
    if point && HasArray(point_data(grid), name)
        RemoveArray(point_data(grid), name)
        removed = true
    end
    if cell && HasArray(cell_data(grid), name)
        RemoveArray(cell_data(grid), name)
        removed = true
    end
    removed && return grid
    error(
        "array '$name' not found in " *
            (point && cell ? "point or cell data" : point ? "point data" : "cell data")
    )
end

"""
    activate_point_data!(grid, name)
    activate_cell_data!(grid, name)

Mark a field-data array as the active scalar for filters like `contour`.
"""
activate_point_data!(grid, name) =
    SetActiveScalars(point_data(grid), String(name))
activate_cell_data!(grid, name) =
    SetActiveScalars(cell_data(grid), String(name))


# ---- multiblock accessors ---------------------------------------------------

nblocks(mb) = GetNumberOfBlocks(mb)

"""
    block(mb, i) -> vtkDataObject (typed via the downcast registry)

Return block `i` (1-based) of a multiblock dataset, downcast to its nearest
registered type. The returned handle owns a VTK reference and can outlive
`mb`; it is not a detached copy.
"""
function block(mb, i::Integer)
    1 <= i <= nblocks(mb) || throw(BoundsError(mb, i))
    obj = GetBlockByIndex(mb, i - 1)
    return downcast(obj)
end

"""
    set_block!(mb, i, grid)

Set block `i` (1-based) of a multiblock dataset. VTK retains its own reference
to `grid`, so the caller does not need to preserve the original handle. The
container and handle continue to refer to the same mutable object.
"""
function set_block!(mb, i::Integer, grid)
    1 <= i <= nblocks(mb) || throw(BoundsError(mb, i))
    SetBlockByIndex(mb, i - 1, grid)
    return mb
end

function MultiBlockDataSet(n::Integer)
    n >= 0 || throw(ArgumentError("number of blocks must be nonnegative, got $n"))
    _drain_vtk_deletions_if_serial()
    mb = MultiBlockDataSet_new()
    SetNumberOfBlocks(mb, n)
    return mb
end
