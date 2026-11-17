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
    algo = EnSightGoldReader_new()
    SetCaseFileName(algo, String(path))
    return VTKTEmporalReader(algo)
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
