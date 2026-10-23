# filters.jl — Julian conveniences over the wrapped VTK filters.

"""
    update!(algo)

Execute `algo` and throw if VTK reported any error/warning while doing so.
"""
function update!(algo)
    Update(_cp(vtkAlgorithm, algo))
    msg = vtk_last_error()
    isempty(msg) || error(msg)
    return algo
end

"""
    plane(origin, normal) -> vtkPlane

Implicit plane through `origin` with `normal`.
"""
function plane(origin, normal)
    p = Plane_new()
    SetOrigin(_cp(vtkPlane, p), origin...)
    SetNormal(_cp(vtkPlane, p), normal...)
    return p
end

"""
    clip(grid, implicitfn; insideout=false) -> vtkUnstructuredGrid

Clip `grid` by an implicit function (see `plane`). Keeps the region where the
function evaluates negative unless `insideout=true`.
"""
function clip(grid, implicitfn; insideout = false)
    f = TableBasedClipDataSet_new()
    SetInputData(_cp(vtkTableBasedClipDataSet, f), _cp(vtkDataSet, grid))
    SetClipFunction(_cp(vtkTableBasedClipDataSet, f), _cp(vtkImplicitFunction, implicitfn))
    SetInsideOut(_cp(vtkTableBasedClipDataSet, f), insideout)
    update!(f)
    return GetOutput(_cp(vtkTableBasedClipDataSet, f))
end

"""
    slice(grid, implicitfn) -> vtkPolyData

Cross-section of `grid` where the implicit function evaluates to zero.
"""
function slice(grid, implicitfn)
    f = Cutter_new()
    SetInputData(_cp(vtkCutter, f), _cp(vtkDataSet, grid))
    SetCutFunction(_cp(vtkCutter, f), _cp(vtkImplicitFunction, implicitfn))
    update!(f)
    return GetOutput(_cp(vtkCutter, f))
end

"""
    cell_to_point(grid) -> vtkDataSet (downcast to access)
    point_to_cell(grid) -> vtkDataSet

Interpolate cell data to points and vice versa.
"""
function cell_to_point(grid)
    f = CellDataToPointData_new()
    SetInputData(_cp(vtkCellDataToPointData, f), _cp(vtkDataSet, grid))
    update!(f)
    return GetOutput(_cp(vtkCellDataToPointData, f))
end

function point_to_cell(grid)
    f = PointDataToCellData_new()
    SetInputData(_cp(vtkPointDataToCellData, f), _cp(vtkDataSet, grid))
    update!(f)
    return GetOutput(_cp(vtkPointDataToCellData, f))
end

"""
    contour(grid, values; scalars=nothing) -> vtkPolyData

Isosurface(s) of the active scalar at the given value(s). Pass `scalars` to
select the point-data array by name (it is activated automatically).
"""
function contour(grid, values; scalars = nothing)
    f = ContourFilter_new()
    SetInputData(_cp(vtkContourFilter, f), _cp(vtkDataSet, grid))
    scalars === nothing || activate_point_data!(grid, scalars)
    for (i, v) in enumerate(values)
        SetContourValue(_cp(vtkContourFilter, f), i - 1, v)
    end
    update!(f)
    return GetOutput(_cp(vtkContourFilter, f))
end

"""
    extract_surface(grid) -> vtkPolyData

External surface of a dataset as polydata.
"""
function extract_surface(grid)
    f = DataSetSurfaceFilter_new()
    SetInputData(_cp(vtkDataSetSurfaceFilter, f), _cp(vtkDataSet, grid))
    update!(f)
    return GetOutput(_cp(vtkDataSetSurfaceFilter, f))
end
