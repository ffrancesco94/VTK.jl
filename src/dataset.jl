# dataset.jl — grid construction, field data access, XML I/O.

UnstructuredGrid() = UnstructuredGrid_new()
UnstructuredGrid(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_unstructuredgrid(obj)
UnstructuredGrid(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_unstructuredgrid(obj)
PolyData(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_polydata(obj)
PolyData(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_polydata(obj)
ImageData(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_imagedata(obj)
ImageData(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_imagedata(obj)
RectilinearGrid(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_rectilineargrid(obj)
RectilinearGrid(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_rectilineargrid(obj)
StructuredGrid(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_structuredgrid(obj)
StructuredGrid(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_structuredgrid(obj)
MultiBlockDataSet(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_multiblock(obj)
MultiBlockDataSet(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_multiblock(obj)
Points() = Points_new()

# ---- generic name-based downcast ------------------------------------------
# DOWNCAST_REGISTRY maps VTK class names (from GetClassName) to typed
# constructors. It is built at module load (__init__) from (type, name,
# downcast-fn) triples, keeping only entries whose type is registered by the
# loaded library — so the hand-written fallback (fewer types) works, and
# adding a grid type to the pipeline needs no edit here.
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
    downcast(obj) -> typed grid

Recover the concrete grid type from a generic `vtkDataObject` (e.g. a
reader/filter output), dispatching on the VTK dynamic class name.
Throws a `KeyError` for unregistered classes.
"""
function downcast(obj::CxxWrap.CxxWrapCore.SmartPointer)
    name = GetClassName(obj)
    return DOWNCAST_REGISTRY[name](obj)
end

# Borrowed raw pointers (e.g. multiblock blocks) carry no smart-pointer
# wrapper; the shim's GetClassName takes vtkObjectBase*, and CxxPtr up-casts
# implicitly at the call boundary.
function downcast(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject})
    name = GetClassName(obj)
    return DOWNCAST_REGISTRY[name](obj)
end

const VTK_HEXAHEDRON = 12
const VTK_TETRA = 10

"""
    insert_cell!(grid, celltype, point_ids)

Insert a cell of `celltype` (e.g. `VTK_HEXAHEDRON`) referencing 0-based
`point_ids` (an integer vector).
"""
function insert_cell!(grid, celltype, point_ids)
    ids = CxxWrap.StdLib.StdVector(Int64.(collect(point_ids)))
    InsertNextCell(grid, celltype, ids)
    return grid
end

Base.setindex!(pts, coord, i) = SetPoint(pts, i - 1, coord...)

npoints!(pts, n) = SetNumberOfPoints(pts, n)

set_points!(grid, pts) = SetPoints(grid, pts)

allocate!(grid, n) = Allocate(grid, n)

point_coordinates(grid, i) = GetPointCoordinates(grid, i - 1)

ncells(grid) = GetNumberOfCells(grid)
npoints(grid) = GetNumberOfPoints(grid)

"""
    points(grid) -> vtkPoints (owning reference)

The points object of a point set.
"""
points(grid) = GetPoints(grid)

"""
    points_array(pts) -> VTKDataArray{T}

The coordinate array of a vtkPoints object (3 components).
"""
points_array(pts) = VTKDataArray(GetPointData(pts))
point_data(grid) = GetPointData(grid)
cell_data(grid) = GetCellData(grid)

field_array_names(fd) =
    [GetArrayNameOf(fd, i) for i in 0:GetNumberOfArrays(fd)-1]

"""
    field_array(fd, name) -> VTKDataArray{T} or nothing

Typed zero-copy view of the named array in field data `fd`.
"""
function field_array(fd, name)
    HasArray(fd, String(name)) || return nothing
    return VTKDataArray(GetArray(fd, String(name)))
end

"""
    field_array_raw(fd, name) -> vtkDataArray smart pointer or nothing

Untyped variant of `field_array`.
"""
function field_array_raw(fd, name)
    HasArray(fd, String(name)) || return nothing
    return GetArray(fd, String(name))
end

function add_array!(fd, da)
    AddArray(fd, da)
    return da
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

# ---- XML I/O ----

"""
    read_vtu(path) -> vtkUnstructuredGrid
    read_vtp(path) -> vtkPolyData
    read_vti(path) -> vtkImageData
    read_vtr(path) -> vtkRectilinearGrid
    read_vts(path) -> vtkStructuredGrid
"""
function read_vtu(path)
    reader = XMLUnstructuredGridReader_new()
    SetFileName(reader, String(path))
    update!(reader)
    return UnstructuredGrid(GetOutput(reader))
end

function read_vtp(path)
    reader = XMLPolyDataReader_new()
    SetFileName(reader, String(path))
    update!(reader)
    return PolyData(GetOutput(reader))
end

function read_vti(path)
    reader = XMLImageDataReader_new()
    SetFileName(reader, String(path))
    update!(reader)
    return ImageData(GetOutput(reader))
end

function read_vtr(path)
    reader = XMLRectilinearGridReader_new()
    SetFileName(reader, String(path))
    update!(reader)
    return RectilinearGrid(GetOutput(reader))
end

function read_vts(path)
    reader = XMLStructuredGridReader_new()
    SetFileName(reader, String(path))
    update!(reader)
    return StructuredGrid(GetOutput(reader))
end

"""
    write_vtu(grid, path)
    write_vtp(polydata, path)
    write_vti(imagedata, path)
    write_vtr(rectilineargrid, path)
    write_vts(structuredgrid, path)
"""
function write_vtu(grid, path; raw_appended = false)
    writer = XMLUnstructuredGridWriter_new()
    if raw_appended
        SetRawAppendedData(writer)
    else
        EnableCompression(writer)
    end
    SetInputData(writer, grid)
    SetFileName(writer, String(path))
    err = Write(writer)
    err == 1 || error("vtkXMLUnstructuredGridWriter failed: $(vtk_last_error())")
    return path
end

function write_vtp(pd, path)
    writer = XMLPolyDataWriter_new()
    EnableCompression(writer)
    SetInputData(writer, pd)
    SetFileName(writer, String(path))
    err = Write(writer)
    err == 1 || error("vtkXMLPolyDataWriter failed: $(vtk_last_error())")
    return path
end

function write_vti(img, path)
    writer = XMLImageDataWriter_new()
    EnableCompression(writer)
    SetInputData(writer, img)
    SetFileName(writer, String(path))
    err = Write(writer)
    err == 1 || error("vtkXMLImageDataWriter failed: $(vtk_last_error())")
    return path
end

function write_vtr(rg, path)
    writer = XMLRectilinearGridWriter_new()
    EnableCompression(writer)
    SetInputData(writer, rg)
    SetFileName(writer, String(path))
    err = Write(writer)
    err == 1 || error("vtkXMLRectilinearGridWriter failed: $(vtk_last_error())")
    return path
end

function write_vts(sg, path)
    writer = XMLStructuredGridWriter_new()
    EnableCompression(writer)
    SetInputData(writer, sg)
    SetFileName(writer, String(path))
    err = Write(writer)
    err == 1 || error("vtkXMLStructuredGridWriter failed: $(vtk_last_error())")
    return path
end

"""
    read_vtm(path) -> vtkMultiBlockDataSet

Read a multiblock XML file (`.vtm`, a container referencing `.vtu`/`.vtp`/
… blocks). Access blocks with `nblocks`/`block(mb, i)`; each block is a
borrowed view — keep the multiblock dataset alive while using them.
"""
function read_vtm(path)
    reader = XMLMultiBlockDataReader_new()
    SetFileName(reader, String(path))
    update!(reader)
    return MultiBlockDataSet(GetOutput(reader))
end

"""
    write_vtm(mb, path)

Write a multiblock dataset (`.vtm` + its block files).
"""
function write_vtm(mb, path)
    writer = XMLMultiBlockDataWriter_new()
    EnableCompression(writer)
    SetInputData(writer, mb)
    SetFileName(writer, String(path))
    err = Write(writer)
    err == 1 || error("vtkXMLMultiBlockDataWriter failed: $(vtk_last_error())")
    return path
end

# ---- multiblock accessors ---------------------------------------------------

nblocks(mb) = GetNumberOfBlocks(mb)

"""
    block(mb, i) -> vtkDataObject (typed via the downcast registry)

Return block `i` (1-based) of a multiblock dataset, downcast to its
concrete type. The block is a borrowed view owned by `mb`.
"""
function block(mb, i::Integer)
    1 <= i <= nblocks(mb) || throw(BoundsError(mb, i))
    obj = GetBlockByIndex(mb, i - 1)
    return downcast(obj)
end

"""
    set_block!(mb, i, grid)

Set block `i` (1-based) of a multiblock dataset. The dataset references
`grid`; keep it alive.
"""
function set_block!(mb, i::Integer, grid)
    1 <= i || throw(BoundsError(mb, i))
    SetBlockByIndex(mb, i - 1, grid)
    return mb
end

MultiBlockDataSet(n::Integer) = let mb = MultiBlockDataSet_new()
    SetNumberOfBlocks(mb, n)
    mb
end