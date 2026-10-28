module VTK

using Libdl
using CxxWrap
using VTK_jll

# VTK_jll is built against MPI; the MPI shared library must be loaded into the
# process before libvtk_julia (and its libvtk* dependencies) are dlopened.
# The flavor depends on the user's MPIPreferences, so handle each possibility.
let mpi_lib = if isdefined(VTK_jll, :MPICH_jll)
        VTK_jll.MPICH_jll.libmpi
    elseif isdefined(VTK_jll, :OpenMPI_jll)
        VTK_jll.OpenMPI_jll.libmpi
    elseif isdefined(VTK_jll, :MPIABI_jll) && isdefined(VTK_jll.MPIABI_jll, :libmpi)
        VTK_jll.MPIABI_jll.libmpi
    else
        nothing
    end
    mpi_lib === nothing || Libdl.dlopen(mpi_lib)
end

# Location of the compiled C++ binding module. Override with ENV["VTKJL_LIB"].
const libvtk_julia = get(ENV, "VTKJL_LIB",
    joinpath(dirname(@__DIR__), "wrapper", "build", "libvtk_julia.so"))

@wrapmodule(() -> libvtk_julia)

function __init__()
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
