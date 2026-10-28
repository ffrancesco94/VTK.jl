# filters.jl — Julian conveniences over the wrapped VTK filters.

"""
    update!(algo)

Execute `algo` and throw if VTK reported any error/warning while doing so.
"""
function update!(algo)
    Update(algo)
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
    SetOrigin(p, origin...)
    SetNormal(p, normal...)
    return p
end

"""
    clip(grid, implicitfn; insideout=false) -> vtkDataObject (downcast to access)

Clip `grid` by an implicit function (see `plane`). Keeps the region where the
function evaluates negative unless `insideout=true`. The output type matches
the input grid type (unstructured, poly, image, structured).
"""
function clip(grid, implicitfn; insideout = false)
    f = TableBasedClipDataSet_new()
    SetInputData(f, grid)
    SetClipFunction(f, implicitfn)
    SetInsideOut(f, insideout)
    update!(f)
    return downcast(GetOutput(f))
end

"""
    slice(grid, implicitfn) -> vtkPolyData

Cross-section of `grid` where the implicit function evaluates to zero.
"""
function slice(grid, implicitfn)
    f = Cutter_new()
    SetInputData(f, grid)
    SetCutFunction(f, implicitfn)
    update!(f)
    return PolyData(GetOutput(f))
end

"""
    cell_to_point(grid) -> vtkDataObject (downcast to access)
    point_to_cell(grid) -> vtkDataObject

Interpolate cell data to points and vice versa. The output type matches the
input grid type.
"""
function cell_to_point(grid)
    f = CellDataToPointData_new()
    SetInputData(f, grid)
    update!(f)
    return downcast(GetOutput(f))
end

function point_to_cell(grid)
    f = PointDataToCellData_new()
    SetInputData(f, grid)
    update!(f)
    return downcast(GetOutput(f))
end

"""
    contour(grid, values; scalars=nothing) -> vtkPolyData

Isosurface(s) of the active scalar at the given value(s). Pass `scalars` to
select the point-data array by name (it is activated automatically).
"""
function contour(grid, values; scalars = nothing)
    f = ContourFilter_new()
    SetInputData(f, grid)
    scalars === nothing || activate_point_data!(grid, scalars)
    for (i, v) in enumerate(values)
        SetContourValue(f, i - 1, v)
    end
    update!(f)
    return PolyData(GetOutput(f))
end

"""
    extract_surface(grid) -> vtkPolyData

External surface of a dataset as polydata.
"""
function extract_surface(grid)
    f = DataSetSurfaceFilter_new()
    SetInputData(f, grid)
    update!(f)
    return PolyData(GetOutput(f))
end
