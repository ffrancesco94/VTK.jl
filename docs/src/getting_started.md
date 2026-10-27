# Getting started

## Installation

VTK.jl is not registered in General yet. Clone it and instantiate:

```julia
using Pkg
Pkg.activate("path/to/VTK.jl")
Pkg.instantiate()
```

The package itself is pure Julia; the heavy dependencies (`VTK_jll` with its
MPI flavor, `CxxWrap`) come from the Julia binary repository automatically.

## Building the C++ wrapper

One compile step is required: the C++ binding module is generated from the
VTK headers by the WrapIt driver and built against the `VTK_jll` artifact.
Requirements: a C++17 toolchain (`g++` or `clang`), `git`, `CMake`, libclang
development headers, and OpenSSL development headers
(`sudo apt-get install g++ cmake git libclang-dev clang libssl-dev` on
Debian/Ubuntu):

```shell
julia --project=. gen/build_wrapper.jl
```

This produces `wrapper/build/libvtk_julia.so` (the wrapit executable itself
is built from source, from [`ffrancesco94/wrapit`](https://github.com/ffrancesco94/wrapit)).
The legacy hand-written CMake wrapper remains available as
`julia --project=. gen/build_wrapper_cmake.jl`.
Override the location with the `VTKJL_LIB` environment variable if you build
it elsewhere — and after switching libraries, clear the precompile cache
(`rm -rf ~/.julia/compiled/v1.*/VTK`), which does not track `VTKJL_LIB`:

```julia
ENV["VTKJL_LIB"] = "/path/to/libvtk_julia.so"
using VTK
```

> MPI note: `VTK_jll` is an MPI-enabled VTK build. `VTK.jl` preloads the
> right `libmpi` (MPICH/OpenMPI/MPI-ABI, per your `MPIPreferences`) before
> any VTK library is opened, so `using VTK` just works. If you use MPI
> yourself, load it before VTK.jl does its thing.

## Running the tests

```shell
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite (131 tests on the merged library, 91 on the hand-written
fallback) includes analytic oracles — e.g. clipping a unit hex
against the plane x+y+z=1 yields exactly the tetrahedron — and
cross-validation against the independent pure-Julia packages ReadVTK.jl and
WriteVTK.jl.

## A first session

```julia-repl
julia> using VTK

julia> pts = VTK.Points();

julia> VTK.npoints!(pts, 4);

julia> pts[1] = (0, 0, 0); pts[2] = (1, 0, 0); pts[3] = (0, 1, 0); pts[4] = (0, 0, 1);

julia> grid = VTK.UnstructuredGrid();

julia> VTK.set_points!(grid, pts);

julia> VTK.allocate!(grid, 1);

julia> VTK.insert_cell!(grid, VTK.VTKCellTypes.VTK_TETRA, [0, 1, 2, 3]);

julia> VTK.ncells(grid), VTK.npoints(grid)
(1, 4)
```

Everything is accessed qualified as `VTK.<name>` — the package intentionally
exports nothing, so it can coexist with other VTK-related packages (VTKBase,
WriteVTK, ReadVTK) in the same session without name clashes.

Next: [build a real mesh](tutorials/mesh.md).
