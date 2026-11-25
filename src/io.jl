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
    update!(reader; filename = path)
    return UnstructuredGrid(checked_output(reader; filename = path))
end

function read_vtp(path)
    reader = XMLPolyDataReader_new()
    SetFileName(reader, String(path))
    update!(reader; filename = path)
    return PolyData(checked_output(reader; filename = path))
end

function read_vti(path)
    reader = XMLImageDataReader_new()
    SetFileName(reader, String(path))
    update!(reader; filename = path)
    return ImageData(checked_output(reader; filename = path))
end

function read_vtr(path)
    reader = XMLRectilinearGridReader_new()
    SetFileName(reader, String(path))
    update!(reader; filename = path)
    return RectilinearGrid(checked_output(reader; filename = path))
end

function read_vts(path)
    reader = XMLStructuredGridReader_new()
    SetFileName(reader, String(path))
    update!(reader; filename = path)
    return StructuredGrid(checked_output(reader; filename = path))
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
    checked_write(writer, path)
    return path
end

function write_vtp(pd, path)
    writer = XMLPolyDataWriter_new()
    EnableCompression(writer)
    SetInputData(writer, pd)
    SetFileName(writer, String(path))
    checked_write(writer, path)
    return path
end

function write_vti(img, path)
    writer = XMLImageDataWriter_new()
    EnableCompression(writer)
    SetInputData(writer, img)
    SetFileName(writer, String(path))
    checked_write(writer, path)
    return path
end

function write_vtr(rg, path)
    writer = XMLRectilinearGridWriter_new()
    EnableCompression(writer)
    SetInputData(writer, rg)
    SetFileName(writer, String(path))
    checked_write(writer, path)
    return path
end

function write_vts(sg, path)
    writer = XMLStructuredGridWriter_new()
    EnableCompression(writer)
    SetInputData(writer, sg)
    SetFileName(writer, String(path))
    checked_write(writer, path)
    return path
end

"""
    read_vtm(path) -> vtkMultiBlockDataSet

Read a multiblock XML file (`.vtm`, a container referencing `.vtu`/`.vtp`/
… blocks). Access blocks with `nblocks`/`block(mb, i)`. Returned blocks own a
VTK reference and may outlive the multiblock handle; parent and child still
refer to the same mutable VTK object.
"""
function read_vtm(path)
    reader = XMLMultiBlockDataReader_new()
    SetFileName(reader, String(path))
    update!(reader; filename = path)
    return MultiBlockDataSet(checked_output(reader; filename = path))
end


# ---- parallel XML readers ----

"""
    read_pvtp(path) -> vtkPolyData

Read a parallel PVTK XML PolyData summary file (`.pvtp`), which references
per-piece `.vtp` files. Returns the merged poly data.
"""
function read_pvtp(path)
    reader = XMLPPolyDataReader_new()
    SetFileName(reader, String(path))
    update!(reader; filename = path)
    return PolyData(checked_output(reader; filename = path))
end

# ---- legacy VTK I/O (.vtk format) ----

"""
    read_legacy_vtk(path) -> vtkDataObject (downcast to access)

Read a legacy VTK file (`.vtk`). The output type depends on the dataset
type stored in the file (unstructured grid, poly data, structured grid,
rectilinear grid, or image data). Use `downcast` on the result or access
it through the generic `vtkDataObject` API.
"""
function read_legacy_vtk(path)
    reader = GenericDataObjectReader_new()
    SetFileName(reader, String(path))
    update!(reader; filename = path)
    return downcast(checked_output(reader; filename = path))
end

"""
    write_legacy_vtk(grid, path)

Write any dataset to a legacy VTK file (`.vtk`). The format is chosen
automatically based on the concrete type of `grid`.
"""
function write_legacy_vtk(grid, path)
    writer = GenericDataObjectWriter_new()
    SetInputData(writer, grid)
    SetFileName(writer, String(path))
    checked_write(writer, path)
    return path
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
    checked_write(writer, path)
    return path
end


# ---- Transient readers ----

abstract type AbstractTemporalReader end


struct VTKTemporalReader{R} <: AbstractTemporalReader
    algorithm::R
    times::Vector{Float64}
    filename::Union{Nothing, String}

    VTKTemporalReader(algo::R, times, filename = nothing) where {R} = new{R}(
        algo,
        Float64.(times),
        filename === nothing ? nothing : String(filename),
    )
end

"""
    timesteps(r::VTKTemporalReader)

Return a copy of the reader's timestep metadata. Mutating the result does not
change the reader.
"""
timesteps(r::VTKTemporalReader) = copy(r.times)

# Keep public metadata isolated without allocating for internal iteration.
_timestep_values(r::VTKTemporalReader) = r.times
_timestep_values(r::AbstractTemporalReader) = timesteps(r)
Base.length(r::AbstractTemporalReader) = length(_timestep_values(r))

"""
  VTKTemporalReader

Constructor for a generic temporal reader. 
"""
function VTKTemporalReader(algo; filename = nothing)
    update_information!(algo; filename = filename)
    return VTKTemporalReader(algo, Float64.(GetTimeSteps(algo)), filename)
end

"""
    EnSightReader(path)

Read an EnSight Gold file. 
"""
function EnSightReader(path)
    filename = String(path)
    algo = GenericEnSightReader_new()
    SetCaseFileName(algo, filename)
    return VTKTemporalReader(algo; filename = filename)
end

"""
    CGNSReader(path)

Reads a CGNS file at path `path`. 
"""
function CGNSReader(path)
    filename = String(path)
    algo = CGNSReader_new()
    SetFileName(algo, filename)

    # Populate bases, time metadata, array selections
    update_information!(algo; filename = filename)

    # Metadata now contains the available arrays
    EnableAllPointArrays(algo)
    EnableAllCellArrays(algo)
    EnableAllFaceArrays(algo)

    return VTKTemporalReader(algo, Float64.(GetTimeSteps(algo)), filename)
end

function _current_output(algo; copy = false, filename = nothing)
    output = checked_output(algo; filename = filename)
    copy && (output = DeepCopyDataObject(output))
    return downcast(output)
end

"""
    read_timestep(reader, i; copy=true)

Load timestep `i` using 1-based indexing.

By default, return an independent deep copy detached from the reader. With
`copy=false`, return an owning handle to the pipeline output whose contents
are borrowed and may be changed by subsequent reader updates; consume or copy
the data before reading another timestep.
"""
function read_timestep(r::VTKTemporalReader, i::Integer; copy = true)
    checkbounds(r.times, i)
    update_time!(r.algorithm, r.times[i]; filename = r.filename)
    return _current_output(r.algorithm; copy = copy, filename = r.filename)
end

"""
    read_at(r::AbstractTemporalReader, time::Real; atol=0, rtol=0, copy=true)

Read the first approximately matching time from the reader, or throw if none
exists. The result is detached by default; `copy=false` explicitly requests
borrowed pipeline contents as in `read_timestep`.
"""
function read_at(
        r::AbstractTemporalReader,
        time::Real;
        atol::Real = 0,
        rtol::Real = 0,
        copy::Bool = true,
    )
    t = Float64(time)
    steps = _timestep_values(r)
    matches = findall(
        x -> isapprox(x, t; atol = atol, rtol = rtol),
        steps,
    )

    isempty(matches) && throw(
        ArgumentError(
            "time $t is unavailable; available times: $steps"
        )
    )

    length(matches) > 1 && throw(
        ArgumentError(
            "time $t matches multiple timesteps at indices $matches; " *
                "use read_timestep(reader, i) or reduce the tolerance"
        )
    )

    return read_timestep(r, only(matches); copy = copy)

end

"""
    eachstep(r::AbstractTemporalReader; copy=true)

Iterate over all timesteps. Each result is detached by default, so collected
results remain valid after later reader updates. Use `copy=false` only when
borrowed pipeline contents are consumed before the next iteration.
"""
eachstep(r::AbstractTemporalReader; copy = true) =
    (read_timestep(r, i; copy = copy) for i in eachindex(_timestep_values(r)))

# One-shot readers are not updated again, so avoid an unnecessary deep copy.
function _read_current(r::VTKTemporalReader, copy = false)
    update!(r.algorithm; filename = r.filename)
    return _current_output(r.algorithm; copy = copy, filename = r.filename)
end

"""
    read_ensight(path)

Read an EnSight Gold file at the prescribed `path`
"""
read_ensight(path) = _read_current(EnSightReader(path))


"""
    read_cgns(path)

Read a CGNS file at the prescribed `path`
"""
read_cgns(path) = _read_current(CGNSReader(path))
