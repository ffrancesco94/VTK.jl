module VTK

using Libdl
using CxxWrap
using VTK_jll
using VTK_julia_jll

# Location of the compiled C++ binding module. Override with ENV["VTKJL_LIB"]
# to use a local development build instead of the JLL artifact.
const libvtk_julia = get(ENV, "VTKJL_LIB", VTK_julia_jll.libvtk_julia)

function load_vtk_libraries()
    # VTK_jll is built against MPI; load its flavor's shared library first.
    mpi_lib = if isdefined(VTK_jll, :MPICH_jll)
        VTK_jll.MPICH_jll.libmpi
    elseif isdefined(VTK_jll, :OpenMPI_jll)
        VTK_jll.OpenMPI_jll.libmpi
    elseif isdefined(VTK_jll, :MPIABI_jll) && isdefined(VTK_jll.MPIABI_jll, :libmpi)
        VTK_jll.MPIABI_jll.libmpi
    else
        nothing
    end
    mpi_lib === nothing || Libdl.dlopen(mpi_lib, Libdl.RTLD_GLOBAL)

    # Relocatable JLL builds do not embed VTK_jll's artifact path. Load the
    # linked VTK components before @initcxx dlopens libvtk_julia.
    for component in (
        "CommonCore",
        "CommonDataModel",
        "CommonExecutionModel",
        "FiltersCore",
        "FiltersGeneral",
        "FiltersFlowPaths",
        "FiltersSources",
        "IOXML",
        "IOEnSight",
        "IOCGNSReader",
        "IOLegacy",
    )
        lib = joinpath(VTK_jll.artifact_dir, "lib",
                       "libvtk$(component)-9.7.$(Libdl.dlext)")
        Libdl.dlopen(lib, Libdl.RTLD_GLOBAL)
    end
    return nothing
end

# Needed while precompiling (@wrapmodule inspects the library), and again in
# __init__ because dlopen state is not preserved in precompile caches.
load_vtk_libraries()
@wrapmodule(() -> libvtk_julia)

function __init__()
    load_vtk_libraries()
    @initcxx
    install_error_window()
    _init_downcast_registry!()
end

# Include order matters: dataarray.jl defines helpers used by the rest.
include("dataarray.jl")
include("generated_methods.jl")
include("typedarray.jl")
include("dataset.jl")
include("cells.jl")
include("filters.jl")

end
