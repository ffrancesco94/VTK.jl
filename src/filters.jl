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

# ---- @vtk_filter macro -------------------------------------------------------
#
# Declarative filter wrapper generation. Eliminates the repetitive
# factory → configure → update! → downcast boilerplate.
#
# Usage:
#   @vtk_filter name(FactoryClass → output; kwargs...) begin
#       # config block: has access to `f` (filter), `grid`, and all kwargs
#   end
#
# For multiple positional arguments, list them before the arrow:
#   @vtk_filter name(grid, implicitfn, FactoryClass → output; kwargs...) begin
#       # config block: has access to `f`, `grid`, `implicitfn`, and kwargs
#   end
#
# Output annotations:
#   → pass_through   : output type matches input (uses downcast)
#   → vtkPolyData    : fixed output type (uses PolyData(...))
#   → auto           : generic downcast (same as pass_through)
#
# The macro generates:
#   function name(grid; kwargs...)
#       f = FactoryClass_new()
#       SetInputData(f, grid)
#       # config block
#       update!(f)
#       return OutputConstructor(GetOutput(f))
#   end

"""
    @vtk_filter(name(args..., Factory → output; kwargs...) begin ... end)

Generate a standard VTK filter wrapper function. The config block has access
to `f` (the filter object), all positional arguments, and all keyword arguments.

# Examples

```julia
# Single input, no extra configuration
@vtk_filter cell_to_point(grid, CellDataToPointData → pass_through) begin
    # no extra configuration
end

# Two positional args, with kwargs
@vtk_filter clip(grid, implicitfn, TableBasedClipDataSet → pass_through;
                insideout=false) begin
    SetClipFunction(f, implicitfn)
    SetInsideOut(f, insideout)
end

# Fixed output type, with kwargs
@vtk_filter contour(grid, values, ContourFilter → vtkPolyData;
                   scalars=nothing) begin
    scalars === nothing || activate_point_data!(grid, scalars)
    for (i, v) in enumerate(values)
        SetContourValue(f, i - 1, v)
    end
end
```
"""
macro vtk_filter(sig, config)
    # Parse: name(arg1, arg2, ..., Factory → output; kwargs...)
    sig.head == :call || error("@vtk_filter: expected name(args..., Factory → output; kwargs...)")

    fname = sig.args[1]

    # Find parameters block (kwargs) and arrow expression
    params_idx = findfirst(a -> isa(a, Expr) && a.head == :parameters, sig.args)
    arrow_idx = findfirst(a -> isa(a, Expr) && a.head == :call && a.args[1] == :→, sig.args)

    arrow_idx === nothing && error("@vtk_filter: expected Factory → Output")

    factory = sig.args[arrow_idx].args[2]
    output = sig.args[arrow_idx].args[3]

    # Positional args are Symbols between fname and arrow (skip parameters block)
    pos_args = Symbol[]
    for i in 2:(arrow_idx - 1)
        if isa(sig.args[i], Symbol)
            push!(pos_args, sig.args[i])
        end
    end
    isempty(pos_args) && push!(pos_args, :grid)  # default

    # Extract kwargs from parameters block
    kwargs = Pair{Symbol,Any}[]
    if params_idx !== nothing
        for kw in sig.args[params_idx].args
            if isa(kw, Expr) && kw.head == :kw
                push!(kwargs, kw.args[1] => kw.args[2])
            end
        end
    end

    # Build kwarg signature
    kwarg_sig = Expr(:parameters, [Expr(:kw, k, v) for (k, v) in kwargs]...)

    # Determine output constructor
    output_str = string(output)
    output_expr = if output_str == "pass_through" || output_str == "auto"
        :(downcast(GetOutput(f)))
    else
        # Strip vtk prefix for the Julia constructor (e.g. vtkPolyData → PolyData)
        ctor_name = replace(output_str, r"^vtk" => "")
        :($(Symbol(ctor_name))(GetOutput(f)))
    end

    # Build the function body
    # Note: config is NOT escaped — it runs inside the function where `f` is defined
    factory_str = string(factory)
    body = quote
        f = $(Symbol(factory_str, "_new"))()
        SetInputData(f, $(pos_args[1]))
        $config
        update!(f)
        return $(output_expr)
    end

    # Assemble the function definition
    # Julia requires: name(; kwargs...) where parameters is the SECOND argument
    func_sig = if isempty(kwargs)
        Expr(:call, esc(fname), esc.(pos_args)...)
    else
        # Parameters block must come right after the function name
        Expr(:call, esc(fname), kwarg_sig, esc.(pos_args)...)
    end

    return Expr(:function, func_sig, body)
end

# ---- filters ----------------------------------------------------------------

"""
    clip(grid, implicitfn; insideout=false) -> vtkDataObject (downcast to access)

Clip `grid` by an implicit function (see `plane`). Keeps the region where the
function evaluates negative unless `insideout=true`. The output type matches
the input grid type (unstructured, poly, image, structured).
"""
@vtk_filter clip(grid, implicitfn, TableBasedClipDataSet → pass_through;
                insideout=false) begin
    SetClipFunction(f, implicitfn)
    SetInsideOut(f, insideout)
end

"""
    slice(grid, implicitfn) -> vtkPolyData

Cross-section of `grid` where the implicit function evaluates to zero.
"""
@vtk_filter slice(grid, implicitfn, Cutter → vtkPolyData) begin
    SetCutFunction(f, implicitfn)
end

"""
    cell_to_point(grid) -> vtkDataObject (downcast to access)
    point_to_cell(grid) -> vtkDataObject

Interpolate cell data to points and vice versa. The output type matches the
input grid type.
"""
@vtk_filter cell_to_point(grid, CellDataToPointData → pass_through) begin
    # no extra configuration
end

@vtk_filter point_to_cell(grid, PointDataToCellData → pass_through) begin
    # no extra configuration
end

"""
    contour(grid, values; scalars=nothing) -> vtkPolyData

Isosurface(s) of the active scalar at the given value(s). Pass `scalars` to
select the point-data array by name (it is activated automatically).
"""
@vtk_filter contour(grid, values, ContourFilter → vtkPolyData;
                   scalars=nothing) begin
    scalars === nothing || activate_point_data!(grid, scalars)
    for (i, v) in enumerate(values)
        SetContourValue(f, i - 1, v)
    end
end

"""
    extract_surface(grid) -> vtkPolyData

External surface of a dataset as polydata.
"""
@vtk_filter extract_surface(grid, DataSetSurfaceFilter → vtkPolyData) begin
    # no extra configuration
end

"""
    calculator(grid; scalars, expression, result="result") -> vtkDataObject

Evaluate a mathematical expression on field data arrays. Variables are
referenced by name; use `scalars` to select the input array (default: active
scalars). The result is stored as a new point-data array named `result`.

# Example

```julia
grid = calculator(grid; scalars="temperature", expression="temperature * 2", result="T2")
```
"""
@vtk_filter calculator(grid, ArrayCalculator → pass_through;
                      scalars=nothing, expression="", result="result") begin
    SetAttributeType(f, 0)  # POINT data
    scalars === nothing || AddScalarVariable(f, String(scalars), String(scalars))
    SetFunction(f, String(expression))
    SetResultArrayName(f, String(result))
end
