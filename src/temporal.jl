abstract type AbstractTemporalReader end

struct VTKTemporalReader{R} <: AbstractTemporalReader
    algorithm::R
    times::Vector{Float64}
end

timesteps(r::VTKTemporalReader) = r.times
Base.length(r::AbstractTemporalReader) = length(timesteps(r))

"""
  update_information!(algo)

Execute the algorithm and throw if VTK reported any error/warning. 
"""
function update_information!(algo)
    ok = UpdateInformation(algo)
    msg = vtk_last_error()
    isempty(msg) || error(msg)
    ok || error("VTK UpdateInformation failed")
    return algo
end

"""
  update_time!(algo)

Call UpdateTimeStep() and throw if VTK exposes any errors. 
"""
function update_time!(algo, time)
    ok = UpdateTimeStep(algo, time)
    msg = vtk_last_error()
    isempty(msg) || error(msg)
    ok != 0 || error("VTK failed while reading time $time")
    return algo
end

"""
  VTKTemporalReader

Constructor for a generic temporal reader. 
"""
function VTKTemporalReader(algo)
    update_information!(algo)
    return VTKTemporalReader(algo, Float64.(GetTimeSteps(algo)))
end

"""
    EnSightReader(path)

Read an EnSight Gold file. 
"""
function EnSightReader(path)
    algo = GenericEnSightReader_new()
    SetCaseFileName(algo, String(path))
    return VTKTemporalReader(algo)
end

"""
    CGNSReader(path)

Reads a CGNS file at path `path`. 
"""
function CGNSReader(path)
    algo = CGNSReader_new()
    SetFileName(algo, String(path))
    return VTKTemporalReader(algo)
end

function _current_output(algo; copy = false)
    output = GetOutput(algo)
    copy && (output = DeepCopyDataObject(output))
    return downcast(output)
end

"""
    read_timestep(reader, i; copy=false)

Load timestep `i` using 1-based indexing. 

With `copy=false`, the result refers to mutable pipeline output and must be
consumed before another timestep is read. With `copy=true`, an independet
deepcopy is returned that is detached from the original reader. 
"""
function read_timestep(r::VTKTemporalReader, i::Integer; copy = false)
    checkbounds(r.times, i)
    update_time!(r.algorithm, r.times[i])
    return _current_output(r.algorithm; copy = copy)
end

"""
    read_at(r::AbstractTemporalReader, time::Real; kwargs...)

Reads the first approximately matching time from the reader, or throw if none exists. 
"""
function read_at(
        r::AbstractTemporalReader,
        time::Real;
        atol::Real = 0,
        rtol::Real = 0,
        copy::Bool = false,
    )
    t = Float64(time)
    matches = findall(
        x -> isapprox(x, t; atol = atol, rtol = rtol),
        timesteps(r),
    )

    isempty(matches) && throw(
        ArgumentError(
            "time $t is unavailable; available times: $(timesteps(r))"
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

eachstep(r::AbstractTemporalReader; copy = false) = (read_timestep(r, i; copy = copy) for i in eachindex(timesteps(r)))

# Shim to get whatever timestep is the default 
function _read_current(r::VTKTemporalReader, copy=false)
    update!(r.algorithm) 
    return _current_output(r.algorithm, copy=copy)
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
