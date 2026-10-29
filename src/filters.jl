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

"""
    gradient(grid; scalars, result="Gradients") -> vtkUnstructuredGrid

Compute the gradient of a scalar field. Pass `scalars` to select the input
array by name (default: active scalars). The result is stored as a new
point-data array named `result` (3-component vectors).

# Example

```julia
grid2 = gradient(grid; scalars="temperature", result="grad_T")
```
"""
@vtk_filter gradient(grid, GradientFilter → vtkUnstructuredGrid;
                    scalars=nothing, result="Gradients") begin
    scalars === nothing || SetInputScalars(f, 0, String(scalars))
    SetResultArrayName(f, String(result))
    SetComputeGradient(f, 1)
end

"""
    threshold(grid; scalars, lower=nothing, upper=nothing, invert=false) -> vtkUnstructuredGrid

Extract cells where the scalar value is within [lower, upper]. Pass `scalars`
to select the input array by name (default: active scalars). Set `invert=true`
to extract cells *outside* the range.

# Example

```julia
hot = threshold(grid; scalars="temperature", lower=1.5, upper=3.0)
```
"""
@vtk_filter threshold(grid, Threshold → vtkUnstructuredGrid;
                     scalars=nothing, lower=nothing, upper=nothing, invert=false) begin
    scalars === nothing || activate_point_data!(grid, scalars)
    lower === nothing || SetLowerThreshold(f, lower)
    upper === nothing || SetUpperThreshold(f, upper)
    SetInvert(f, invert)
end

"""
    stream_tracer(grid, seeds; vectors, integration_direction="forward") -> vtkPolyData

Trace streamlines through a vector field. `seeds` is a vtkDataSet with seed
points (e.g. from `line_source`). Pass `vectors` to select the vector array
by name (default: active vectors).

# Example

```julia
seeds = line_source((0.5, 0.5, 0.0), (0.5, 0.5, 1.0); resolution=10)
lines = stream_tracer(grid, seeds; vectors="velocity")
```
"""
@vtk_filter stream_tracer(grid, seeds, StreamTracer → vtkPolyData;
                         vectors=nothing, integration_direction="forward") begin
    vectors === nothing || activate_point_data!(grid, vectors)
    SetSourceData(f, seeds)
    if integration_direction == "backward"
        SetIntegrationDirection(f, 0)
    elseif integration_direction == "both"
        SetIntegrationDirection(f, 2)
    else
        SetIntegrationDirection(f, 1)  # forward
    end
end

"""
    particle_tracer(grid, seeds; vectors) -> vtkPolyData

Trace particles through a vector field (advection). `seeds` is a vtkDataSet
with seed points. Pass `vectors` to select the vector array by name.

# Example

```julia
seeds = line_source((0.5, 0.5, 0.0), (0.5, 0.5, 1.0); resolution=10)
particles = particle_tracer(grid, seeds; vectors="velocity")
```
"""
@vtk_filter particle_tracer(grid, seeds, ParticleTracer → vtkPolyData;
                           vectors=nothing) begin
    vectors === nothing || activate_point_data!(grid, vectors)
    AddSourceConnection(f, GetOutputPort(seeds))
end

"""
    line_source(p1, p2; resolution=100) -> vtkPolyData

Generate a line of points from `p1` to `p2` with `resolution` points. Useful
as seed points for `stream_tracer` or `particle_tracer`, or as a probe line
for `sample_over_line`.

# Example

```julia
line = line_source((0.5, 0.5, 0.0), (0.5, 0.5, 1.0); resolution=50)
```
"""
function line_source(p1, p2; resolution=100)
    src = LineSource_new()
    SetPoint1(src, Float64.(p1)...)
    SetPoint2(src, Float64.(p2)...)
    SetResolution(src, resolution)
    update!(src)
    return PolyData(GetOutput(src))
end

"""
    sample_over_line(grid, p1, p2; resolution=100, scalars=nothing) -> vtkDataSet

Sample a dataset along a line from `p1` to `p2` with `resolution` points.
Returns a dataset with the sampled values. This is the VTK equivalent of
ParaView's "Plot Over Line".

# Example

```julia
profile = sample_over_line(grid, (0.5, 0.5, 0.0), (0.5, 0.5, 1.0); resolution=50)
```
"""
function sample_over_line(grid, p1, p2; resolution=100, scalars=nothing)
    line = line_source(p1, p2; resolution=resolution)
    probe = ProbeFilter_new()
    SetInputData(probe, line)   # points to probe at
    SetSourceData(probe, grid)  # dataset to probe from
    update!(probe)
    return downcast(GetOutput(probe))
end
