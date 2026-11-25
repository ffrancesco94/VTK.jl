# Scoped VTK operation diagnostics.
#
# Each native Scoped* call owns its observer and diagnostic collector. Separate
# algorithms may therefore execute concurrently without a global lock. As with
# VTK generally, concurrently executing or mutating the same algorithm is not
# supported. Nested scoped calls attach independent observers, so both receive
# events emitted while they are active.

const _VTK_SEVERITIES = (:error, :warning, :text, :debug)

"""A single diagnostic emitted by a VTK algorithm during one operation."""
struct VTKDiagnostic
    severity::Symbol
    message::String
    operation::Symbol
    algorithm::String
    filename::Union{Nothing,String}

    VTKDiagnostic(severity, message, operation, algorithm, filename = nothing) = new(
        Symbol(severity),
        String(message),
        Symbol(operation),
        String(algorithm),
        filename === nothing ? nothing : String(filename),
    )
end

"""An unsuccessful VTK operation, including every diagnostic it emitted."""
struct VTKError <: Exception
    operation::Symbol
    algorithm::String
    filename::Union{Nothing,String}
    status::Int
    diagnostics::Vector{VTKDiagnostic}
end

function Base.showerror(io::IO, err::VTKError)
    print(io, "VTK ", err.operation, " failed on ", err.algorithm)
    err.filename === nothing || print(io, " for '", err.filename, "'")
    print(io, " (status ", err.status, ")")
    for diagnostic in err.diagnostics
        print(io, "\n  [", diagnostic.severity, "] ", diagnostic.message)
    end
end

"""
    VTKTypeError(expected, actual)

A VTK object had type `actual` where `expected` was required. Both arguments
are converted to strings, so VTK type names may be strings or symbols.
"""
struct VTKTypeError <: Exception
    expected::String
    actual::String

    VTKTypeError(expected, actual) = new(string(expected), string(actual))
end

function Base.showerror(io::IO, err::VTKTypeError)
    print(io, "VTK type error: expected ", err.expected, ", got ", err.actual)
end

"""
    VTKUnsupportedTypeError(vtk_type)

The dynamic VTK class `vtk_type` is not supported by the requested high-level
accessor (for example, a nonnumeric array passed to the numeric zero-copy API).
Pass just the VTK class name, not a preformatted error message.
"""
struct VTKUnsupportedTypeError <: Exception
    vtk_type::String

    VTKUnsupportedTypeError(vtk_type) = new(string(vtk_type))
end

function Base.showerror(io::IO, err::VTKUnsupportedTypeError)
    print(io, "unsupported VTK type '", err.vtk_type, "'")
end

# Symbols are convenient at Julia test and call sites; the native helper also
# accepts "error", "warning", "text", and "debug" strings.
EmitDiagnostic(algo::VTKSmartPointer{<:vtkAlgorithm}, severity::Symbol, message) =
    EmitDiagnostic(algo, String(severity), String(message))

function _vtk_algorithm_class(algo)
    name = String(GetClassName(algo))
    return isempty(name) ? string(typeof(algo)) : name
end

function _vtk_severity(code)
    index = Int(code) + 1
    1 <= index <= length(_VTK_SEVERITIES) ||
        throw(ArgumentError("unknown VTK diagnostic severity code $code"))
    return _VTK_SEVERITIES[index]
end

# Convert the native (status, severity_codes, messages) tuple into a fully
# contextualized result. This internal helper is also useful for deterministic
# Julia-side tests of the warning/error policy.
function _vtk_operation_result(native_result, operation, algo, filename)
    status, severity_codes, messages = native_result
    length(severity_codes) == length(messages) ||
        error("VTK returned mismatched diagnostic severities and messages")

    operation = Symbol(operation)
    algorithm = _vtk_algorithm_class(algo)
    filename = filename === nothing ? nothing : String(filename)
    diagnostics = VTKDiagnostic[]
    sizehint!(diagnostics, length(severity_codes))
    for (code, message) in zip(severity_codes, messages)
        push!(
            diagnostics,
            VTKDiagnostic(
                _vtk_severity(code), String(message), operation, algorithm, filename
            ),
        )
    end
    return (
        operation = operation,
        algorithm = algorithm,
        filename = filename,
        status = Int(status),
        diagnostics = diagnostics,
    )
end

function _check_vtk_result(result)
    for diagnostic in result.diagnostics
        if diagnostic.severity === :warning
            @warn diagnostic.message operation = diagnostic.operation algorithm =
                diagnostic.algorithm filename = diagnostic.filename
        end
    end
    if result.status == 0 ||
       any(diagnostic -> diagnostic.severity === :error, result.diagnostics)
        throw(VTKError(
            result.operation,
            result.algorithm,
            result.filename,
            result.status,
            result.diagnostics,
        ))
    end
    return result.status
end

"""
    update_with_diagnostics(algo; filename=nothing, operation=:Update)

Execute `algo` with a fresh scoped observer and return a named tuple with
`status`, `diagnostics`, `operation`, `algorithm`, and `filename` fields.
`diagnostics` contains every error, warning, text, and debug record in emission
order. `Update` uses status 1 when no error was captured and 0 otherwise.

This inspection variant does not log diagnostics or throw for VTK error events
or a zero status; use [`update!`](@ref) for the checked form. Native argument
and binding errors still throw. Concurrent mutation/execution of the same VTK
algorithm is unsupported.
"""
function update_with_diagnostics(algo; filename = nothing, operation = :Update)
    _drain_vtk_deletions_if_serial()
    result = _vtk_operation_result(
        ScopedUpdate(algo), operation, algo, filename
    )
    # vtkAlgorithm::Update returns void. Its persistent error code covers
    # pipeline failures that do not emit a fresh error event on every call.
    code = Int(GetErrorCode(_cp(vtkAlgorithm, algo)))
    code == 0 && return result
    diagnostics = copy(result.diagnostics)
    any(d -> d.severity === :error, diagnostics) || push!(diagnostics,
        VTKDiagnostic(:error, "VTK algorithm error code $code",
                      result.operation, result.algorithm, result.filename))
    return merge(result, (status = 0, diagnostics = diagnostics))
end

"""
    update!(algo; filename=nothing, operation=:Update) -> algo

Execute `algo` with scoped diagnostics. Emit one `@warn` log per VTK warning,
ignore nonfatal text/debug records, and throw [`VTKError`](@ref) for an error
record or failed status. Warnings alone do not throw. `filename` may identify a
file or case file and is included in diagnostics and errors.
"""
function update!(algo; filename = nothing, operation = :Update)
    result = update_with_diagnostics(algo; filename, operation)
    _check_vtk_result(result)
    return algo
end

function _vtk_output_error(algo, operation, filename, detail)
    operation = Symbol(operation)
    algorithm = _vtk_algorithm_class(algo)
    filename = filename === nothing ? nothing : String(filename)
    message = "GetOutput could not acquire an owning output"
    isempty(detail) || (message *= ": " * detail)
    diagnostic = VTKDiagnostic(
        :error, message, operation, algorithm, filename
    )
    return VTKError(operation, algorithm, filename, 0, [diagnostic])
end

"""
    checked_output(algo; operation=:Update, filename=nothing) -> owning output

Call the raw `GetOutput(algo)` and return its owning `vtkDataObject` smart
pointer. A null result or native `take_ref` failure is converted to
[`VTKError`](@ref) with operation, algorithm class, optional filename, status
0, and an error diagnostic containing the native detail. `operation` accepts a
symbol or string.

No points, cells, or other dataset-cardinality checks are performed: a non-null
empty dataset is a successful output. The raw `GetOutput` binding is unchanged.
"""
function checked_output(algo; operation = :Update, filename = nothing)
    _drain_vtk_deletions_if_serial()
    output = try
        GetOutput(algo)
    catch exception
        detail = strip(sprint(showerror, exception))
        throw(_vtk_output_error(algo, operation, filename, detail))
    end
    output === nothing &&
        throw(_vtk_output_error(algo, operation, filename, "null output"))
    return output
end

"""
    update_information!(algo; filename=nothing) -> algo

Checked `UpdateInformation`: log warnings and throw [`VTKError`](@ref) on an
error diagnostic or zero native status. The native status is otherwise kept.
"""
function update_information!(algo; filename = nothing)
    _drain_vtk_deletions_if_serial()
    result = _vtk_operation_result(
        ScopedUpdateInformation(algo), :UpdateInformation, algo, filename
    )
    _check_vtk_result(result)
    return algo
end

"""
    update_time!(algo, time; filename=nothing) -> algo

Checked `UpdateTimeStep(time)`: log warnings and throw [`VTKError`](@ref) on an
error diagnostic or zero native status.
"""
function update_time!(algo, time; filename = nothing)
    _drain_vtk_deletions_if_serial()
    result = _vtk_operation_result(
        ScopedUpdateTimeStep(algo, Float64(time)),
        :UpdateTimeStep,
        algo,
        filename,
    )
    _check_vtk_result(result)
    return algo
end

"""
    checked_write(writer, filename=nothing; operation=:Write) -> status
    checked_write(writer, operation, filename) -> status

Execute a VTK writer with scoped diagnostics. Log warnings and throw
[`VTKError`](@ref) for an error diagnostic or zero native status. On success,
return the native writer status (normally 1). The optional three-argument form
allows callers to provide a more specific operation label.
"""
function checked_write(writer, filename = nothing; operation = :Write)
    _drain_vtk_deletions_if_serial()
    result = _vtk_operation_result(
        ScopedWrite(writer), operation, writer, filename
    )
    return _check_vtk_result(result)
end

checked_write(writer, operation::Union{Symbol,AbstractString}, filename) =
    checked_write(writer, filename; operation)
