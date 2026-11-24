#!/usr/bin/env julia
# WrapIt driver: regenerate the VTKGen wrapper module from VTK headers.
#
#   julia --project=gen/wrapit gen/wrapit/build.jl
#
# Pipeline:
#   1. render wrapit.toml from the template with runtime artifact paths
#   2. build upstream wrapit from source (wrapit_src.jl) and run it on the
#      input headers
#   3. generate the mechanical shim from the headers (auto_shim.jl)
#   4. generate Julia smart-pointer forwarding overloads
#   5. post-process the generated C++ (AOS leaf-array fake superclasses,
#      WrapIt bug 2 workaround)
#   6. compile the generated module + shims against VTK_jll
#
# C++/build products land in
# gen/wrapit/build/{cxx,jl,shipped,wrapit-src,wrapit-build}; the tracked Julia
# forwarding layer is regenerated at src/generated_methods.jl.
using VTK_jll
using CxxWrap

const DRIVER_DIR = @__DIR__
const BUILD_DIR = joinpath(DRIVER_DIR, "build")

include(joinpath(DRIVER_DIR, "auto_shim.jl"))
include(joinpath(DRIVER_DIR, "smartptr_wrappers.jl"))
include(joinpath(DRIVER_DIR, "wrapit_src.jl"))

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
    tpl = read(joinpath(DRIVER_DIR, "VTK.wit.in"), String)
    s = replace(tpl, "__VTK_INCLUDE__" => vtk_include_dir())
    s = replace(s, "__VETO_LIST__" => joinpath(DRIVER_DIR, "veto.txt"))
    mpi = mpi_include_dir()
    s = replace(s, "__MPI_INCLUDE__" =>
        mpi === nothing ? "" : "\"$mpi\",")
    write(joinpath(BUILD_DIR, "wrapit.toml"), s)
end

# ---- step 2: generate (upstream wrapit, Bug 1 fixed) ---------------------

function run_wrapit()
    exe = ensure_wrapit!()
    cd(() -> run(Cmd([exe, "--force", "-v", "0", "wrapit.toml"])), BUILD_DIR)
end

# Guard against a regression of WrapIt bug 1 (silent truncation): the
# generated file must not contain a bare `// defined in ` line (empty
# source location followed by end-of-file).
function check_generation_complete!()
    f = joinpath(BUILD_DIR, "cxx", "JlClasses.cxx")
    isfile(f) || error("wrapit did not produce $f")
    any(l -> l == "    // defined in ", readlines(f)) &&
        error("wrapit output truncated (bug-1 marker found in $f)")
end

function generate!()
    mkpath(BUILD_DIR)
    render_config!()
    run_wrapit()
    check_generation_complete!()
    check_shim_types_registered!()
end

# Every vtk class type referenced by the merged shim must be registered by
# the generated module (add_type), otherwise boxing fails at module load
# with "No appropriate factory for type ...". Catches input-list omissions.
function check_shim_types_registered!()
    shim = read(joinpath(DRIVER_DIR, "shim_vtkjl.cpp"), String)
    classes = read(joinpath(BUILD_DIR, "cxx", "JlClasses.cxx"), String)
    used = Set(m.match for m in eachmatch(r"vtk[A-Z]\w+", shim))
    internal = ("vtkIdType", "vtkTypeBool", "vtkNew", "vtkOutputWindow",
                "vtkJuliaOutputWindow", "vtkSmartPointer", "vtkArrayDispatch",
                # macros / includes / comments, never boxed as class types
                "vtkAOSDataArrayTemplate", "vtkArrayTypes", "vtkObjectFactory",
                "vtkStandardNewMacro", "vtkTypeMacro", "vtkType", "vtkInformation", "vtkStreamingDemandDrivenPipeline")
    missing = sort!(collect(t for t in used if
        !any(startswith(t, p) for p in internal) &&
        !occursin("add_type<$t>", classes)))
    isempty(missing) ||
        error("shim references types the generated module does not register: ",
              join(missing, ", "), " — add their headers to VTK.wit.in")
    println("shim type audit OK (", length(used), " referenced types registered)")
end

# Generated methods whose Julia signature collides with a shim registration
# (same name, same argument types up to default-argument truncation) must be
# vetoed: CxxWrap rejects double registration and Julia forbids method
# overwriting during precompilation. Detect mechanically; persist vetoes.
function veto_shim_clashes!()
    shim = read(joinpath(DRIVER_DIR, "shim_vtkjl.cpp"), String) *
           read(joinpath(BUILD_DIR, "cxx", "shim_auto.cpp"), String)
    gen = read(joinpath(BUILD_DIR, "cxx", "JlClasses.cxx"), String)
    shim_sigs = Dict{String,Vector{Tuple}}()
    for m in eachmatch(r"mod\.method\(\"(\w+)\",\s*\[\]\((.*?)\)\s*(?:->| \{)"s, shim)
        push!(get!(shim_sigs, m.captures[1], Tuple[]),
              Tuple(norm_shim_args(m.captures[2]; strip_names = true)))
    end
    veto_file = joinpath(DRIVER_DIR, "veto.txt")
    vetoes = Set(filter(!isempty, strip.(readlines(veto_file))))
    # class → direct base map (for base/derived string ambiguities)
    parent = Dict{String,String}()
    for m in eachmatch(r"add_type<(vtk\w+)>\(\"[^\"]+\"(?:,\s*jlcxx::julia_base_type<(vtk\w+)>\(\))?\s*\)", gen)
        m.captures[2] === nothing || (parent[m.captures[1]] = m.captures[2])
    end
    function is_derived(child, ancestor)
        c = child
        while haskey(parent, c)
            c = parent[c]
            c == ancestor && return true
        end
        return false
    end
    added = String[]
    for m in eachmatch(r"// signature to use in the veto list: (.+?) ([\w:]+)::(\w+)\((.*?)\)\s*$"m, gen)
        ret, cls, name, args = m.captures
        name in keys(shim_sigs) || continue
        full = Tuple(vcat([cls], norm_shim_args(args)))
        hit = any(shim_sigs[name]) do s
            length(s) <= length(full) && s == full[1:length(s)]
        end
        # The shim is preferred whenever it offers the same method on a
        # related class (same class, or base/derived): exact-type matches
        # would double-register, and std::string (shim) vs const char*
        # (generated) — which WrapIt maps to Julia String too — would make
        # calls ambiguous (e.g. SetActiveScalars on vtkDataSetAttributes vs
        # our vtkPointData/vtkCellData versions, or the generic
        # SetInputData/GetOutput on vtkAlgorithm vs per-class generated
        # ones). Veto the generated overload; the shim version wins.
        hit || (hit = any(shim_sigs[name]) do s
            length(s) <= length(full) &&
                (s[1] == full[1] || is_derived(s[1], full[1]) ||
                 is_derived(full[1], s[1])) &&
                all(i -> s[i] == full[i] ||
                         (s[i] == "std::string" && full[i] == "int8_t"),
                    2:length(s))
        end)
        if hit
            v = "$ret $cls::$name($args)"
            if v ∉ vetoes
                push!(vetoes, v); push!(added, v)
            end
        end
    end
    if !isempty(added)
        open(veto_file, "a") do io
            foreach(l -> println(io, l), added)
        end
        println("added ", length(added), " shim-clash vetoes; REGENERATE")
        generate!()   # rerun with the new vetoes (converges: fixed point)
    end
end

# ---- step 3: post-process ---------------------------------------------------

# AOS leaf arrays: WrapIt drops the vtkAOSDataArrayTemplate<T> base as an
# unmappable template (bug 2); re-point them at vtkDataArray, exactly like
# the hand-written wrapper's fake-superclass trick.
const AOS_LEAF_ARRAYS =
    ["vtkDoubleArray", "vtkFloatArray", "vtkIntArray", "vtkUnsignedCharArray"]

# Other public classes whose direct VTK parent is not mapped by WrapIt.
# Re-point them at the nearest registered public ancestor. This preserves the
# C++ is-a relationship for CxxPtr/SmartPointer dispatch without wrapping every
# intermediate implementation class.
const PARENT_FIXES = [
    "vtkStructuredGrid" => "vtkPointSet",       # vtkStructuredData mixin
    "vtkImageData" => "vtkDataSet",             # vtkCartesianGrid
    "vtkRectilinearGrid" => "vtkDataSet",       # vtkStructuredData mixin
    "vtkMultiBlockDataSet" => "vtkDataObject",  # vtkDataObjectTree
    "vtkIdTypeArray" => "vtkDataArray",         # vtkAOSDataArrayTemplate
    "vtkXMLMultiBlockDataReader" => "vtkXMLReader",
    "vtkXMLMultiBlockDataWriter" => "vtkXMLWriter",
]

function postprocess!()
    classes = joinpath(BUILD_DIR, "cxx", "JlClasses.cxx")
    s = read(classes, String)
    # (1) AOS leaf arrays: WrapIt drops the vtkAOSDataArrayTemplate<T> base
    # as unmappable template; re-point at vtkDataArray (fake-superclass
    # trick, same as the retired hand-written wrapper).
    for c in AOS_LEAF_ARRAYS
        s = replace(s,
            "add_type<$c>(\"$c\")" =>
            "add_type<$c>(\"$c\", jlcxx::julia_base_type<vtkDataArray>())")
    end
    shim = "\nnamespace jlcxx {\n" * join(
        "  template<> struct SuperType<$c> { typedef vtkDataArray type; };\n"
        for c in AOS_LEAF_ARRAYS) * "}\n"
    # (2) repair the remaining dropped public parent chains (bug 2 family).
    parent_shims = Pair{String,String}[]
    for (child, parent) in PARENT_FIXES
        bare = "add_type<$child>(\"$child\")"
        fixed = "add_type<$child>(\"$child\", jlcxx::julia_base_type<$parent>())"
        if occursin(bare, s)
            s = replace(s, bare => fixed)
            push!(parent_shims, child => parent)
        else
            # Newer libclang versions may recover some of these parents
            # themselves; accept that case, but never hide an unexpected one.
            occursin(Regex("add_type<$child>\\(\"$child\",\\s*" *
                            "jlcxx::julia_base_type<$parent>\\(\\)\\)"), s) ||
                error("parent-fix target not found: $child")
        end
    end
    shim = "\nnamespace jlcxx {\n" * join(
        "  template<> struct SuperType<$child> { typedef $parent type; };\n"
        for (child, parent) in parent_shims) * "}\n" * shim
    # The smart-pointer traits must be visible in EVERY TU that boxes
    # vtkSmartPointer returns (factory selection is per translation unit);
    # ToAOSDataArray in this file returns vtkSmartPointer<vtkDataArray>.
    s = replace(s, "#include \"jlVTKGen.h\"" =>
        "#include \"jlVTKGen.h\"\n#include \"shim_vtkjl.h\"\n" * shim; count = 1)
    # (3) strip WrapIt's parametric vtkSmartPointer wrapper (the merged
    # module registers REAL smart-pointer support instead).
    s = strip_vtksmartpointer(s)
    write(classes, s)

    # (3) steering file: drop the removed wrapper's references, merge the
    # hand-written ownership/shim layer into the module init.
    steer = joinpath(BUILD_DIR, "cxx", "jlVTKGen.cxx")
    t = read(steer, String)
    t = replace(t,
        "std::shared_ptr<Wrapper> newJlvtkSmartPointer(jlcxx::Module&);\n" => "")
    t = replace(t, "class JlvtkSmartPointer;\n" => "")
    t = replace(t,
        "    std::shared_ptr<Wrapper>(newJlvtkSmartPointer(jlModule)),\n" => "")
    occursin("newJlvtkSmartPointer", t) &&
        error("residual newJlvtkSmartPointer references in steering file")
    t = replace(t, "#include \"jlVTKGen.h\"" =>
                     "#include \"jlVTKGen.h\"\n#include \"shim_vtkjl.h\""; count = 1)
    loop = "for(const auto& w: wrappers) w->add_methods();"
    occursin(loop, t) || error("add_methods loop not found")
    t = replace(t, loop =>
        "  register_shim_methods(jlModule); // merged ownership/shim layer\n" *
        "  register_auto_shim_methods(jlModule); // generated factories+accessors\n" * loop,
        count = 1)
    write(steer, t)
    println("post-processed JlClasses.cxx + jlVTKGen.cxx")
end

const SP_TRAITS = r"namespace jlcxx \{\s*template<typename \w+>\s*struct BuildParameterList<vtkSmartPointer<\w+>>.*?\n\}\n"s
const SP_STRUCT = r"// Class generating the wrapper for type vtkSmartPointer\n// signature to use in the veto file: vtkSmartPointer\nstruct JlvtkSmartPointer.*?\n\};\nstd::shared_ptr<Wrapper> newJlvtkSmartPointer\(jlcxx::Module& module\)\{\n  return std::shared_ptr<Wrapper>\(new JlvtkSmartPointer\(module\)\);\n\}\n"s

function strip_vtksmartpointer(s)
    for (name, pat) in ("SP traits" => SP_TRAITS, "SP struct" => SP_STRUCT)
        m = match(pat, s)
        m === nothing && error("pattern not found: $name")
        s = replace(s, pat => ""; count = 1)
    end
    return s
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
             "vtkFiltersCore", "vtkFiltersGeneral", "vtkFiltersFlowPaths",
             "vtkFiltersSources", "vtkIOXML",
             "vtkIOEnSight", "vtkIOCGNSReader", "vtkIOLegacy"]
    [joinpath(libdir, only(filter(n -> startswith(n, "lib$m-") &&
                                      endswith(n, ".so"), readdir(libdir))))
     for m in names]
end

function compile!()
    cxxwrap_inc = joinpath(CxxWrap.prefix_path(), "include")
    julia_inc = joinpath(Sys.BINDIR, Base.INCLUDEDIR, "julia")
    isdir(julia_inc) ||
        error("julia headers not found at $julia_inc (source build?)")
    shipped = joinpath(BUILD_DIR, "shipped")
    mkpath(shipped)
    common = String["-shared", "-fPIC", "-std=c++17",
                    "-I$(joinpath(BUILD_DIR, "cxx"))",
                    "-I$DRIVER_DIR",
                    "-I$cxxwrap_inc", "-I$julia_inc",
                    "-I$(vtk_include_dir())",
                    "-L$(joinpath(VTK_jll.artifact_dir, "lib"))",
                    "-Wl,-rpath,$(joinpath(VTK_jll.artifact_dir, "lib"))"]
    mpi = mpi_include_dir()
    mpi === nothing || push!(common, "-I$mpi")
    libs = vtk_libs()
    cc = compiler()
    # ONE merged library: WrapIt-generated code + the hand-written
    # ownership/shim layer (injected into the generated JLCXX_MODULE by
    # postprocess.py). It is a drop-in replacement for the hand-built
    # wrapper/build/libvtk_julia.so (override via ENV["VTKJL_LIB"]).
    run(Cmd([cc; common;
             "-o"; joinpath(shipped, "libvtk_julia.so");
             joinpath(BUILD_DIR, "cxx", "jlVTKGen.cxx");
             joinpath(BUILD_DIR, "cxx", "JlClasses.cxx");
             joinpath(DRIVER_DIR, "shim_vtkjl.cpp");
             joinpath(BUILD_DIR, "cxx", "shim_auto.cpp"); libs]))
    println("built: ", joinpath(shipped, "libvtk_julia.so"))
end

# ---- main --------------------------------------------------------------------

generate!()
generate_auto_shim!(DRIVER_DIR, BUILD_DIR, vtk_include_dir())
veto_shim_clashes!()
generate_smartptr_wrappers!(DRIVER_DIR, BUILD_DIR,
                            joinpath(dirname(dirname(DRIVER_DIR)), "src",
                                     "generated_methods.jl"))
postprocess!()
compile!()
println("""
Done. Smoke-test the generated module with:

    julia --project=gen/wrapit gen/wrapit/generated_library_integration.jl
""")
