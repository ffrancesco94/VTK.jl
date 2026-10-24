#!/usr/bin/env julia
# WrapIt driver: regenerate the VTKGen wrapper module from VTK headers.
#
#   julia --project=gen/wrapit gen/wrapit/build.jl
#
# Pipeline (see docs/wrapit-spike.md):
#   1. render wrapit.toml from the template with runtime artifact paths
#   2. run wrapit; auto-vetoes macro-generated methods that would truncate
#      the output (WrapIt bug 1) until generation completes
#   3. post-process the generated C++ (AOS leaf-array fake superclasses,
#      WrapIt bug 2 workaround)
#   4. compile the generated module + the accessor shim against VTK_jll
#
# Products land in gen/wrapit/build/{cxx,jl}; nothing outside gen/wrapit
# and the depot is touched.
using VTK_jll
using CxxWrap
using WrapIt_jll

const DRIVER_DIR = @__DIR__
const BUILD_DIR = joinpath(DRIVER_DIR, "build")

# ---- artifact paths --------------------------------------------------------

vtk_include_dir() = let d = joinpath(VTK_jll.artifact_dir, "include")
    joinpath(d, only(readdir(d)))
end

mpi_include_dir() =
    if isdefined(VTK_jll, :MPICH_jll)
        joinpath(VTK_jll.MPICH_jll.artifact_dir, "include")
    elseif isdefined(VTK_jll, :OpenMPI_jll)
        joinpath(VTK_jll.OpenMPI_jll.artifact_dir, "include")
    elseif isdefined(VTK_jll, :MPIABI_jll) && isdefined(VTK_jll.MPIABI_jll, :artifact_dir)
        joinpath(VTK_jll.MPIABI_jll.artifact_dir, "include")
    else
        nothing
    end

function render_config!()
    tpl = read(joinpath(DRIVER_DIR, "wrapit.toml.template"), String)
    s = replace(tpl, "__VTK_INCLUDE__" => vtk_include_dir())
    s = replace(s, "__VETO_LIST__" => joinpath(DRIVER_DIR, "veto.txt"))
    mpi = mpi_include_dir()
    s = replace(s, "__MPI_INCLUDE__" =>
        mpi === nothing ? "" : "\"$mpi\",")
    write(joinpath(BUILD_DIR, "wrapit.toml"), s)
end

# ---- step 2: generate, with the Bug 1 veto loop ----------------------------

truncated_signature() = let f = joinpath(BUILD_DIR, "cxx", "JlClasses.cxx")
    isfile(f) || return nothing
    lines = readlines(f)
    any(l -> l == "    // defined in ", lines) || return nothing
    sig = nothing
    for l in lines
        m = match(r"signature to use in the veto list: (.*)$", l)
        m !== nothing && (sig = m.captures[1])
    end
    sig   # last complete signature = the method that killed generation
end

function run_wrapit()
    WrapIt_jll.wrapit() do exe
        cd(() -> run(Cmd([exe, "--force", "-v", "0", "wrapit.toml"])), BUILD_DIR)
    end
end

function generate!()
    mkpath(BUILD_DIR)
    render_config!()
    vetoes = readlines(joinpath(DRIVER_DIR, "veto.txt"))
    for iter in 0:200
        run_wrapit()
        sig = truncated_signature()
        if sig === nothing
            println(iter == 0 ? "generation complete (no new vetoes)" :
                               "generation complete after $iter new vetoes")
            write(joinpath(DRIVER_DIR, "veto.txt"), join(vetoes, "\n") * "\n")
            return
        end
        sig in vetoes && error("veto had no effect: $sig")
        push!(vetoes, sig)
        println("vetoed (WrapIt bug 1): $sig")
    end
    error("veto loop did not converge in 200 iterations")
end

# ---- step 3: post-process ---------------------------------------------------

# AOS leaf arrays: WrapIt drops the vtkAOSDataArrayTemplate<T> base as an
# unmappable template (bug 2); re-point them at vtkDataArray, exactly like
# the hand-written wrapper's fake-superclass trick.
const AOS_LEAF_ARRAYS =
    ["vtkDoubleArray", "vtkFloatArray", "vtkIntArray", "vtkUnsignedCharArray"]

function postprocess!()
    f = joinpath(BUILD_DIR, "cxx", "JlClasses.cxx")
    s = read(f, String)
    for c in AOS_LEAF_ARRAYS
        s = replace(s,
            "add_type<$c>(\"$c\")" =>
            "add_type<$c>(\"$c\", jlcxx::julia_base_type<vtkDataArray>())")
    end
    shim = """

// POST-PROCESSED (WrapIt bug 2 workaround): fake superclasses for AOS leaf
// arrays, whose real parent vtkAOSDataArrayTemplate<T> is unmappable.
namespace jlcxx {
""" * join(["  template<> struct SuperType<$c> { typedef vtkDataArray type; };\n"
        for c in AOS_LEAF_ARRAYS]) * "}\n"
    s = replace(s, "#include \"jlVTKGen.h\"" =>
                     "#include \"jlVTKGen.h\"\n" * shim; count = 1)
    write(f, s)
    println("post-processed ", basename(f))
end

# ---- step 4: compile --------------------------------------------------------

compiler() = Sys.which("g++") !== nothing ? Sys.which("g++") :
             Sys.which("c++") !== nothing ? Sys.which("c++") :
             error("no C++ compiler found (need g++ or c++)")

# VTK module libraries the generated code links against (resolve the
# versioned artifact names, e.g. libvtkCommonCore-9.7.so).
function vtk_libs()
    libdir = joinpath(VTK_jll.artifact_dir, "lib")
    names = ["vtkCommonCore", "vtkCommonDataModel", "vtkCommonExecutionModel",
             "vtkFiltersCore", "vtkFiltersGeneral", "vtkIOXML"]
    [joinpath(libdir, only(filter(n -> startswith(n, "lib$m-") &&
                                      endswith(n, ".so"), readdir(libdir))))
     for m in names]
end

function compile!()
    cxxwrap_inc = joinpath(CxxWrap.prefix_path(), "include")
    julia_inc = joinpath(Sys.BINDIR, Base.INCLUDEDIR, "julia")
    isdir(julia_inc) ||
        error("julia headers not found at $julia_inc (source build?)")
    deps = joinpath(BUILD_DIR, "jl", "deps")
    mkpath(deps)
    common = String["-shared", "-fPIC", "-std=c++17",
                    "-I$(joinpath(BUILD_DIR, "cxx"))",
                    "-I$cxxwrap_inc", "-I$julia_inc",
                    "-I$(vtk_include_dir())",
                    "-L$(joinpath(VTK_jll.artifact_dir, "lib"))",
                    "-Wl,-rpath,$(joinpath(VTK_jll.artifact_dir, "lib"))"]
    mpi = mpi_include_dir()
    mpi === nothing || push!(common, "-I$mpi")
    libs = vtk_libs()
    cc = compiler()
    run(Cmd([cc; common; "-o"; joinpath(deps, "libjlVTKGen.so");
             joinpath(BUILD_DIR, "cxx", "jlVTKGen.cxx");
             joinpath(BUILD_DIR, "cxx", "JlClasses.cxx"); libs]))
    run(Cmd([cc; common; "-o"; joinpath(deps, "libjlVTKGenShim.so");
             joinpath(DRIVER_DIR, "shim.cpp"); libs]))
    println("built: ", joinpath(deps, "libjlVTKGen.so"))
    println("built: ", joinpath(deps, "libjlVTKGenShim.so"))
end

# ---- main --------------------------------------------------------------------

generate!()
postprocess!()
compile!()
println("""
Done. Smoke-test the generated module with:

    julia --project=gen/wrapit gen/wrapit/conformance.jl
""")
