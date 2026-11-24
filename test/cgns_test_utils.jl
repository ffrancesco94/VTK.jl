using CGNS_jll: libcgns

# Talem frp, cgnslib.h
const CG_MODE_WRITE = Cint(1)
const CG_STRUCTURED = Cint(2)
const CG_VERTEX = Cint(2)
const CG_REAL_DOUBLE = Cint(4)
const CG_CHARACTER = Cint(5)
const CG_TIME_ACCURATE = Cint(3)

function cgns_check(status::Cint)
    status == 0 && return nothing

    message = unsafe_string(
        ccall((:cg_get_error, libcgns), Cstring, ())
    )
    error("CGNS library error: $message")
end


"""
    write_cgns_cse(path; times=nothing)

Write a 2x2x2 structured CGNS grid. 

Without `times`, write one static flow field. With `times`, write one field per
time and connect them using BaseIterativeData and FlowSolutionPointers. 
"""
function write_cgns_case(path; times = nothing)
    transient = (times !== nothing)
    time_values = transient ? Float64.(times) : Float64[]
    nsolutions = transient ? length(time_values) : 1

    nsolutions > 0 || throw(ArgumentError("A transient CGNS file needs at leat one time value"))

    # Julia's first array index varies the fastest, matching CGNS's i-j-k order
    x = Float64[0, 1, 0, 1, 0, 1, 0, 1]
    y = Float64[0, 0, 1, 1, 0, 0, 1, 1]
    z = Float64[0, 0, 0, 0, 1, 1, 1, 1]

    base_density = [
        Float64(i + 2j + 4k)
            for i in 0:1, j in 0:1, k in 0:1
    ]

    solution_names = if transient
        ["FlowSolution$s" for s in 1:nsolutions]
    else
        ["FlowSolution"]
    end

    file = Ref{Cint}(0)
    base = Ref{Cint}(0)
    zone = Ref{Cint}(0)
    opened = false

    try
        cgns_check(
            ccall(
                (:cg_open, libcgns),
                Cint,
                (Cstring, Cint, Ref{Cint}),
                String(path), CG_MODE_WRITE, file
            )
        )
        opened = true
        cgns_check(
            ccall(
                (:cg_base_write, libcgns),
                Cint,
                (Cint, Cstring, Cint, Cint, Ref{Cint}),
                file[], "Base", 3, 3, base
            )
        )

        # Structured-zone dimensions:
        # vertex counts, cell counts, boundary-vertex counts.
        #
        # CGNS_jll uses 64-bit cgsize_t on supported 64-bit platforms.
        zone_size = Int64[
            2, 2, 2, # 2x2x2 vertices
            1, 1, 1, # 1x1x1 cells
            0, 0, 0,  # Noboundary vertices for a structured zone
        ]

        cgns_check(
            ccall(
                (:cg_zone_write, libcgns),
                Cint,
                (Cint, Cint, Cstring, Ptr{Int64}, Cint, Ref{Cint}),
                file[], base[], "Zone", zone_size, CG_STRUCTURED, zone
            )
        )

        for (name, values) in (
                ("CoordinateX", x),
                ("CoordinateY", y),
                ("CoordinateZ", z),
            )
            coordinate = Ref{Cint}(0)

            cgns_check(
                ccall(
                    (:cg_coord_write, libcgns),
                    Cint,
                    (Cint, Cint, Cint, Cint, Cstring, Ptr{Cvoid}, Ref{Cint}),
                    file[], base[], zone[], CG_REAL_DOUBLE, name, values, coordinate
                )
            )
        end

        for s in 1:nsolutions
            solution = Ref{Cint}(0)
            field = Ref{Cint}(0)

            cgns_check(
                ccall(
                    (:cg_sol_write, libcgns),
                    Cint,
                    (Cint, Cint, Cint, Cstring, Cint, Ref{Cint}),
                    file[], base[], zone[],
                    solution_names[s], CG_VERTEX, solution,
                )
            )

            density = base_density .+ 10.0 * (s - 1)

            cgns_check(
                ccall(
                    (:cg_field_write, libcgns),
                    Cint,
                    (
                        Cint, Cint, Cint, Cint, Cint,
                        Cstring, Ptr{Cvoid}, Ref{Cint},
                    ),
                    file[], base[], zone[], solution[], CG_REAL_DOUBLE,
                    "Density", density, field,
                )
            )
        end

        if transient
            cgns_check(
                ccall(
                    (:cg_biter_write, libcgns),
                    Cint,
                    (Cint, Cint, Cstring, Cint),
                    file[], base[], "TimeIterValues", nsolutions,
                )
            )

            cgns_check(
                ccall(
                    (:cg_goto, libcgns),
                    Cint,
                    (Cint, Cint, Cstring, Cint, Cstring),
                    file[], base[],
                    "BaseIterativeData_t", 1, "end",
                )
            )

            time_dimensions = Int64[nsolutions]

            cgns_check(
                ccall(
                    (:cg_array_write, libcgns),
                    Cint,
                    (Cstring, Cint, Cint, Ptr{Int64}, Ptr{Cvoid}),
                    "TimeValues", CG_REAL_DOUBLE, 1,
                    time_dimensions, time_values,
                )
            )

            cgns_check(
                ccall(
                    (:cg_ziter_write, libcgns),
                    Cint,
                    (Cint, Cint, Cint, Cstring),
                    file[], base[], zone[], "ZoneIterativeData",
                )
            )

            cgns_check(
                ccall(
                    (:cg_goto, libcgns),
                    Cint,
                    (
                        Cint, Cint,
                        Cstring, Cint,
                        Cstring, Cint,
                        Cstring,
                    ),
                    file[], base[],
                    "Zone_t", zone[],
                    "ZoneIterativeData_t", 1,
                    "end",
                )
            )

            # Each solution name occupies one space-padded 32-byte column.
            pointers = fill(0x20, 32, nsolutions)

            for (s, name) in enumerate(solution_names)
                bytes = codeunits(name)
                pointers[1:length(bytes), s] .= bytes
            end

            pointer_dimensions = Int64[32, nsolutions]

            cgns_check(
                ccall(
                    (:cg_array_write, libcgns),
                    Cint,
                    (Cstring, Cint, Cint, Ptr{Int64}, Ptr{Cvoid}),
                    "FlowSolutionPointers", CG_CHARACTER, 2,
                    pointer_dimensions, pointers,
                )
            )

            cgns_check(
                ccall(
                    (:cg_simulation_type_write, libcgns),
                    Cint,
                    (Cint, Cint, Cint),
                    file[], base[], CG_TIME_ACCURATE,
                )
            )
        end
    finally
        if opened
            cgns_check(
                ccall(
                    (:cg_close, libcgns),
                    Cint,
                    (Cint,),
                    file[],
                )
            )
        end
    end

    return String(path)

end

function cgns_zone(mb)
    VTK.nblocks(mb) == 1 || error("expected one CGNS base")

    base = VTK.block(mb, 1)
    VTK.nblocks(base) == 1 || error("expected one CGNS zone")

    return VTK.block(base, 1)
end

function density_values(mb)
    zone = cgns_zone(mb)
    array = VTK.field_array(VTK.point_data(zone), "Density")

    array === nothing && error("missing CGNS Density array")
    return copy(vec(VTK.data(array)))
end
