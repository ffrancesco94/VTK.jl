"""
    bounds(grid) -> Tuple 

Return bounding box values of the dataset. 
"""
bounds(grid::VTKSmartPointer{<:vtkDataSet}) =
    Tuple(collect(GetBoundsValues(grid)))

"""
    center(grid) -> Tuple 

Return the centre of the dataset geometry as the mean of the bounding box. 
"""
function center(grid::VTKSmartPointer{<:vtkDataSet})
    xmin, xmax, ymin, ymax, zmin, zmax = bounds(grid)
    return (
        (xmin + xmax) / 2,
        (ymin + ymax) / 2,
        (zmin + zmax) / 2,
    )
end

"""
    dimensions(grid) -> Tuple 

Return the dimensions of a structured grid. 
"""
dimensions(grid::VTKSmartPointer{<:vtkStructuredGrid}) = Tuple(Int.(collect(GetDimensionsValues(grid))))


"""
    extent(grid) -> Tuple 

Return the extents of a structured grid. 
"""
extent(grid::VTKSmartPointer{<:vtkStructuredGrid}) = Tuple(Int.(collect(GetExtentValues(grid))))

"""
    origin(image) -> Tuple 

Return the origin of a vtkImageData dataset. 
"""
origin(image::VTKSmartPointer{<:vtkImageData}) = Tuple(collect(GetOriginValues(image)))

"""
    spacing(image) -> Tuple 

Return the spacing of a vtkImageData dataset. 
"""
spacing(image::VTKSmartPointer{<:vtkImageData}) = Tuple(collect(GetSpacingValues(image)))

"""
    direction(image)

Return the directions of a vtkImageData dataset. 
"""
function direction(image::VTKSmartPointer{<:vtkImageData})
    values = collect(GetDirectionValues(image))

    # The original matrix is row-major
    return permutedims(reshape(values, 3, 3))
end

function array_range(
        array::VTKDataArray;
        component::Integer = -1,
        finite::Bool = false
    )
    -1 <= component < ncomponents(array) || throw(BoundsError(0:(ncomponents(array) - 1), component))

    return Tuple(
        collect(
            GetArrayRangeValues(
                array.obj,
                component,
                finite
            )
        )
    )
end


# ---- Better displays for REPL use ----

function Base.show(io::IO, grid::VTKSmartPointer{<:vtkDataSet})
    return print(
        io,
        GetClassName(grid),
        "(points=", npoints(grid),
        ", cells=", ncells(grid), ")"
    )
end

function Base.show(
        io::IO,
        ::MIME"text/plain",
        grid::VTKSmartPointer{<:vtkDataSet},
    )
    println(io, GetClassName(grid))
    println(io, "  points: ", npoints(grid))
    println(io, "  cells:  ", ncells(grid))
    println(io, "  bounds: ", bounds(grid))

    for (label, association) in (
            ("point", point_data(grid)),
            ("cell", cell_data(grid)),
            ("field", field_data(grid)),
        )
        names = keys(association)
        println(
            io, "  $label arrays: ",
            isempty(names) ? "none" : join(names, ", ")
        )
    end

    for (label, association) in ((:point, :point), (:cell, :cell))
        active = active_array(
            grid;
            association = association,
            attribute = :scalars,
        )
        println(
            io, "  active $label scalars: ",
            active === nothing ? "none" : name(active)
        )
    end
    return
end
