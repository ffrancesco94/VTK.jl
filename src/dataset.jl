# dataset.jl — grid construction, field data access, XML I/O.

UnstructuredGrid() = UnstructuredGrid_new()
UnstructuredGrid(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_unstructuredgrid(_cp(vtkDataObject, obj))
PolyData(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_polydata(_cp(vtkDataObject, obj))
ImageData(obj::CxxWrap.CxxWrapCore.SmartPointer) =
    downcast_imagedata(_cp(vtkDataObject, obj))
Points() = Points_new()

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
    points_array(pts) -> vtkDataArray (owning reference)

The coordinate array of a vtkPoints object (3 components).
"""
points_array(pts) = GetPointData(_cp(vtkPoints, pts))
point_data(grid) = GetPointData(_cp(vtkDataSet, grid))
cell_data(grid) = GetCellData(_cp(vtkDataSet, grid))

field_array_names(fd) =
    [GetArrayNameOf(_cp(vtkFieldData, fd), i) for i in 0:GetNumberOfArrays(_cp(vtkFieldData, fd))-1]

"""
    field_array(fd, name) -> vtkDataArray or nothing

Reference to the named array in field data `fd`.
"""
function field_array(fd, name)
    try
        return GetArray(_cp(vtkFieldData, fd), String(name))
    catch
        return nothing
    end
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
"""
function read_vtu(path)
    reader = XMLUnstructuredGridReader_new()
    SetFileName(_cp(vtkXMLUnstructuredGridReader, reader), String(path))
    update!(reader)
    return GetOutput(_cp(vtkXMLUnstructuredGridReader, reader))
end

function read_vtp(path)
    reader = XMLPolyDataReader_new()
    SetFileName(_cp(vtkXMLPolyDataReader, reader), String(path))
    update!(reader)
    return GetOutput(_cp(vtkXMLPolyDataReader, reader))
end

"""
    write_vtu(grid, path)
    write_vtp(polydata, path)
"""
function write_vtu(grid, path; raw_appended = false)
    writer = XMLUnstructuredGridWriter_new()
    if raw_appended
        SetRawAppendedData(_cp(vtkXMLUnstructuredGridWriter, writer))
    else
        EnableCompression(_cp(vtkXMLUnstructuredGridWriter, writer))
    end
    SetInputData(_cp(vtkXMLUnstructuredGridWriter, writer), _cp(vtkUnstructuredGrid, grid))
    SetFileName(_cp(vtkXMLUnstructuredGridWriter, writer), String(path))
    err = Write(_cp(vtkXMLUnstructuredGridWriter, writer))
    err == 1 || error("vtkXMLUnstructuredGridWriter failed: $(vtk_last_error())")
    return path
end

function write_vtp(pd, path)
    writer = XMLPolyDataWriter_new()
    EnableCompression(_cp(vtkXMLPolyDataWriter, writer))
    SetInputData(_cp(vtkXMLPolyDataWriter, writer), _cp(vtkPolyData, pd))
    SetFileName(_cp(vtkXMLPolyDataWriter, writer), String(path))
    err = Write(_cp(vtkXMLPolyDataWriter, writer))
    err == 1 || error("vtkXMLPolyDataWriter failed: $(vtk_last_error())")
    return path
end
