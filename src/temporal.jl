abstract type AbstractTemporalReader end

struct VTKTemporalReader{R} <: AbstractTemporalReader
    algorithm::R
    times::Vector{Float64}
    filename::Union{Nothing,String}

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
