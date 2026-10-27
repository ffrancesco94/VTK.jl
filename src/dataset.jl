# dataset.jl — grid construction, field data access, XML I/O.

UnstructuredGrid() = UnstructuredGrid_new()
UnstructuredGrid(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_unstructuredgrid(_cp(vtkDataObject, obj))
UnstructuredGrid(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_unstructuredgrid(obj)
PolyData(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_polydata(_cp(vtkDataObject, obj))
PolyData(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_polydata(obj)
ImageData(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_imagedata(_cp(vtkDataObject, obj))
ImageData(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_imagedata(obj)
RectilinearGrid(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_rectilineargrid(_cp(vtkDataObject, obj))
RectilinearGrid(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_rectilineargrid(obj)
StructuredGrid(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_structuredgrid(_cp(vtkDataObject, obj))
StructuredGrid(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_structuredgrid(obj)
MultiBlockDataSet(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_multiblock(_cp(vtkDataObject, obj))
MultiBlockDataSet(obj::CxxWrap.CxxWrapCore.CxxPtr{<:vtkDataObject}) =
    downcast_multiblock(obj)
Points() = Points_new()

# ---- generic name-based downcast ------------------------------------------
# Maps VTK class names (from GetClassName) to the typed constructor. Adding
# a new grid type = one registry entry + its downcast_foo shim binding.
const DOWNCAST_REGISTRY = Dict{String, Function}(
    "vtkUnstructuredGrid" => UnstructuredGrid,
    "vtkPolyData" => PolyData,
    "vtkImageData" => ImageData,
    "vtkRectilinearGrid" => RectilinearGrid,
    "vtkStructuredGrid" => StructuredGrid,
    "vtkMultiBlockDataSet" => MultiBlockDataSet,
)

"""
    downcast(obj) -> typed grid

Recover the concrete grid type from a generic `vtkDataObject` (e.g. a
reader/filter output), dispatching on the VTK dynamic class name.
Throws a `KeyError` for unregistered classes.
"""
function downcast(obj::CxxWrap.CxxWrapCore.SmartPointer)
    name = GetClassName(_cp(vtkObjectBase, obj))
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
    InsertNextCell(_cp(vtkUnstructuredGrid, grid), celltype, ids)
    return grid
end

Base.setindex!(pts, coord, i) = SetPoint(_cp(vtkPoints, pts), i - 1, coord...)

npoints!(pts, n) = SetNumberOfPoints(_cp(vtkPoints, pts), n)

set_points!(grid, pts) = SetPoints(_cp(vtkPointSet, grid), _cp(vtkPoints, pts))

allocate!(grid, n) = Allocate(_cp(vtkUnstructuredGrid, grid), n)

point_coordinates(grid, i) = GetPointCoordinates(_cp(vtkPointSet, grid), i - 1)

ncells(grid) = GetNumberOfCells(_cp(vtkDataSet, grid))
npoints(grid) = GetNumberOfPoints(_cp(vtkPointSet, grid))

"""
    points(grid) -> vtkPoints (owning reference)

The points object of a point set.
"""
points(grid) = GetPoints(_cp(vtkPointSet, grid))

"""
    points_array(pts) -> VTKDataArray{T}

The coordinate array of a vtkPoints object (3 components).
"""
points_array(pts) = VTKDataArray(GetPointData(_cp(vtkPoints, pts)))
point_data(grid) = GetPointData(_cp(vtkDataSet, grid))
cell_data(grid) = GetCellData(_cp(vtkDataSet, grid))

field_array_names(fd) =
    [GetArrayNameOf(_cp(vtkFieldData, fd), i) for i in 0:GetNumberOfArrays(_cp(vtkFieldData, fd))-1]

"""
    field_array(fd, name) -> VTKDataArray{T} or nothing

Typed zero-copy view of the named array in field data `fd`.
"""
function field_array(fd, name)
    HasArray(_cp(vtkFieldData, fd), String(name)) || return nothing
    return VTKDataArray(GetArray(_cp(vtkFieldData, fd), String(name)))
end

"""
    field_array_raw(fd, name) -> vtkDataArray smart pointer or nothing

Untyped variant of `field_array`.
"""
function field_array_raw(fd, name)
    HasArray(_cp(vtkFieldData, fd), String(name)) || return nothing
    return GetArray(_cp(vtkFieldData, fd), String(name))
end

function add_array!(fd, da)
    AddArray(_cp(vtkFieldData, fd), _cp(vtkDataArray, da))
    return da
end

"""
    activate_point_data!(grid, name)
    activate_cell_data!(grid, name)

Mark a field-data array as the active scalar for filters like `contour`.
"""
activate_point_data!(grid, name) =
    SetActiveScalars(_cp(vtkPointData, point_data(grid)), String(name))
activate_cell_data!(grid, name) =
    SetActiveScalars(_cp(vtkCellData, cell_data(grid)), String(name))

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
    SetFileName(_cp(vtkXMLUnstructuredGridReader, reader), String(path))
    update!(reader)
    return UnstructuredGrid(GetOutput(_cp(vtkAlgorithm, reader)))
end

function read_vtp(path)
    reader = XMLPolyDataReader_new()
    SetFileName(_cp(vtkXMLPolyDataReader, reader), String(path))
    update!(reader)
    return PolyData(GetOutput(_cp(vtkAlgorithm, reader)))
end

function read_vti(path)
    reader = XMLImageDataReader_new()
    SetFileName(_cp(vtkXMLImageDataReader, reader), String(path))
    update!(reader)
    return ImageData(GetOutput(_cp(vtkAlgorithm, reader)))
end

function read_vtr(path)
    reader = XMLRectilinearGridReader_new()
    SetFileName(_cp(vtkXMLRectilinearGridReader, reader), String(path))
    update!(reader)
    return RectilinearGrid(GetOutput(_cp(vtkAlgorithm, reader)))
end

function read_vts(path)
    reader = XMLStructuredGridReader_new()
    SetFileName(_cp(vtkXMLStructuredGridReader, reader), String(path))
    update!(reader)
    return StructuredGrid(GetOutput(_cp(vtkAlgorithm, reader)))
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
        SetRawAppendedData(_cp(vtkXMLUnstructuredGridWriter, writer))
    else
        EnableCompression(_cp(vtkXMLUnstructuredGridWriter, writer))
    end
    SetInputData(_cp(vtkAlgorithm, writer), _cp(vtkDataObject, grid))
    SetFileName(_cp(vtkXMLUnstructuredGridWriter, writer), String(path))
    err = Write(_cp(vtkXMLUnstructuredGridWriter, writer))
    err == 1 || error("vtkXMLUnstructuredGridWriter failed: $(vtk_last_error())")
    return path
end

function write_vtp(pd, path)
    writer = XMLPolyDataWriter_new()
    EnableCompression(_cp(vtkXMLPolyDataWriter, writer))
    SetInputData(_cp(vtkAlgorithm, writer), _cp(vtkDataObject, pd))
    SetFileName(_cp(vtkXMLPolyDataWriter, writer), String(path))
    err = Write(_cp(vtkXMLPolyDataWriter, writer))
    err == 1 || error("vtkXMLPolyDataWriter failed: $(vtk_last_error())")
    return path
end

function write_vti(img, path)
    writer = XMLImageDataWriter_new()
    EnableCompression(_cp(vtkXMLImageDataWriter, writer))
    SetInputData(_cp(vtkAlgorithm, writer), _cp(vtkDataObject, img))
    SetFileName(_cp(vtkXMLImageDataWriter, writer), String(path))
    err = Write(_cp(vtkXMLImageDataWriter, writer))
    err == 1 || error("vtkXMLImageDataWriter failed: $(vtk_last_error())")
    return path
end

function write_vtr(rg, path)
    writer = XMLRectilinearGridWriter_new()
    EnableCompression(_cp(vtkXMLRectilinearGridWriter, writer))
    SetInputData(_cp(vtkAlgorithm, writer), _cp(vtkDataObject, rg))
    SetFileName(_cp(vtkXMLRectilinearGridWriter, writer), String(path))
    err = Write(_cp(vtkXMLRectilinearGridWriter, writer))
    err == 1 || error("vtkXMLRectilinearGridWriter failed: $(vtk_last_error())")
    return path
end

function write_vts(sg, path)
    writer = XMLStructuredGridWriter_new()
    EnableCompression(_cp(vtkXMLStructuredGridWriter, writer))
    SetInputData(_cp(vtkAlgorithm, writer), _cp(vtkDataObject, sg))
    SetFileName(_cp(vtkXMLStructuredGridWriter, writer), String(path))
    err = Write(_cp(vtkXMLStructuredGridWriter, writer))
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
    SetFileName(_cp(vtkXMLMultiBlockDataReader, reader), String(path))
    update!(reader)
    return MultiBlockDataSet(GetOutput(_cp(vtkAlgorithm, reader)))
end

"""
    write_vtm(mb, path)

Write a multiblock dataset (`.vtm` + its block files).
"""
function write_vtm(mb, path)
    writer = XMLMultiBlockDataWriter_new()
    EnableCompression(_cp(vtkXMLMultiBlockDataWriter, writer))
    SetInputData(_cp(vtkAlgorithm, writer), _cp(vtkDataObject, mb))
    SetFileName(_cp(vtkXMLMultiBlockDataWriter, writer), String(path))
    err = Write(_cp(vtkXMLMultiBlockDataWriter, writer))
    err == 1 || error("vtkXMLMultiBlockDataWriter failed: $(vtk_last_error())")
    return path
end

# ---- multiblock accessors ---------------------------------------------------

nblocks(mb) = GetNumberOfBlocks(_cp(vtkMultiBlockDataSet, mb))

"""
    block(mb, i) -> vtkDataObject (typed via the downcast registry)

Return block `i` (1-based) of a multiblock dataset, downcast to its
concrete type. The block is a borrowed view owned by `mb`.
"""
function block(mb, i::Integer)
    1 <= i <= nblocks(mb) || throw(BoundsError(mb, i))
    obj = GetBlockByIndex(_cp(vtkMultiBlockDataSet, mb), i - 1)
    return downcast(obj)
end

"""
    set_block!(mb, i, grid)

Set block `i` (1-based) of a multiblock dataset. The dataset references
`grid`; keep it alive.
"""
function set_block!(mb, i::Integer, grid)
    1 <= i || throw(BoundsError(mb, i))
    SetBlockByIndex(_cp(vtkMultiBlockDataSet, mb), i - 1, _cp(vtkDataObject, grid))
    return mb
end

MultiBlockDataSet(n::Integer) = let mb = MultiBlockDataSet_new()
    SetNumberOfBlocks(_cp(vtkMultiBlockDataSet, mb), n)
    mb
end