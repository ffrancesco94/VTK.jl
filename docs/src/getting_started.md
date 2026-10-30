# Getting started

## Installation

VTK.jl is not registered in General yet, so we need to get it from GitHub:

```julia
using Pkg
Pkg.add("git+https://github.com/ffrancesco94/VTK.jl")
```

The package itself is pure Julia; the heavy dependencies (`VTK_jll`, `CxxWrap`,
and the pre-built `libvtk_julia` wrapper via `VTK_julia_jll`) come from the
Julia binary repository automatically. No local C++ toolchain is required.

## The C++ wrapper

The C++ binding module (`libvtk_julia`) is available as a pre-built binary
through `VTK_julia_jll` on Yggdrasil for supported platforms. This should just
work:tm:.

### Local development

For development or unsupported platforms, the wrapper can still be built
locally from the VTK.jl source tree. Requirements: a C++17 toolchain (`g++` or
`clang`, `git`, `CMake`, libclang development headers, and OpenSSL development
headers (`sudo apt-get install g++ cmake git libclang-dev clang libssl-dev` on
Debian/Ubuntu). At the time of writing (October 2026), a
[bug](https://github.com/grasph/wrapit/issues/76) is present in WrapIt which
makes it much harder to wrap VTK. Because of that, I am using a fork under
[https://github.com/ffrancesco94/wrapit](https://github.com/ffrancesco94/wrapit). As per their
[instructions](https://github.com/grasph/wrapit#build-from-source), `clang` 19
is needed to build it (22 was breaking some things for me). After that:

```shell
julia --project=. gen/build_wrapper.jl
```

This produces `gen/wrapit/build/shipped/libvtk_julia.so`. Override the
location with the `VTKJL_LIB` environment variable, and after switching
libraries, clear the precompile cache (`rm -rf ~/.julia/compiled/v1.*/VTK`),
which does not track `VTKJL_LIB`:

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
julia -e 'using Pkg; Pkg.test()'
```

The suite (180 tests) includes analytic validations (e.g. clipping a unit hex
against the plane x+y+z=1 yields exactly the tetrahedron) and cross-validation
against the independent pure-Julia packages ReadVTK.jl and WriteVTK.jl.

## A first session

```julia
using VTK

# A single tetrahedron
coords = [0.0 1.0 0.0 0.0;
          0.0 0.0 1.0 0.0;
          0.0 0.0 0.0 1.0]
cells = [VTK.MeshCell(VTK.VTKCellTypes.VTK_TETRA, [1, 2, 3, 4])]

grid = VTK.UnstructuredGrid(coords, cells)

# Attach a scalar field
p = VTK.data_array(Float64, 1)
VTK.resize!(p, 4)
VTK.name!(p, "p")
p[1, :] .= [1.0, 2.0, 3.0, 4.0]
VTK.add_array!(VTK.point_data(grid), p)

VTK.write_vtu(grid, "tetra.vtu")
```

Everything is accessed qualified as `VTK.<name>` — the package intentionally
exports nothing, so it can coexist with other VTK-related packages (VTKBase,
WriteVTK, ReadVTK) in the same session without name clashes.

Next: [build a real mesh](tutorials/mesh.md).
