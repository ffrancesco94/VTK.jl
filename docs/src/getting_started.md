# Getting started

## Installation

VTK.jl is not registered in General yet, so we need to get it from GitHub.
For a stable install, pin a release tag — each VTK.jl tag pairs with a
matching pre-built `VTK_julia_jll`:

```julia
using Pkg
Pkg.add(url="https://github.com/ffrancesco94/VTK.jl", rev="v0.1.0")  # latest tag
```

Installing `main` instead gives the latest development state, but the Julia
code on `main` may expect wrapper bindings newer than the newest published
`VTK_julia_jll` — on `main`, build the wrapper locally (below) and select it
with `VTKJL_LIB`.

The package itself is pure Julia; the heavy dependencies (`VTK_jll`, `CxxWrap`,
and the pre-built `libvtk_julia` wrapper via `VTK_julia_jll`) come from the
Julia binary repository automatically. No local C++ toolchain is required
when installing a release tag.

## The C++ wrapper

When installed from a release tag, the C++ binding module (`libvtk_julia`)
is available as a pre-built binary through `VTK_julia_jll` on Yggdrasil for
supported platforms. This should just work:tm:.

### Local development

For development or unsupported platforms, the wrapper can still be built
locally from the VTK.jl source tree. Requirements: a C++17 toolchain (`g++` or
`clang`, `git`, `CMake`, libclang development headers, and OpenSSL development
headers (`sudo apt-get install g++ cmake git libclang-dev clang libssl-dev` on
Debian/Ubuntu). The build clones and compiles
[upstream WrapIt](https://github.com/grasph/wrapit), which includes the
macro-generation and libclang-22 fixes needed by VTK.jl. Then run:

```shell
julia --project=. gen/build_wrapper.jl
```

This produces `wrapper/build/libvtk_julia.so`. Override the location with the
`VTKJL_LIB` environment variable, and after switching libraries, clear the
precompile cache (`rm -rf ~/.julia/compiled/v1.*/VTK`), which does not track
`VTKJL_LIB`. From the repository root:

```julia
ENV["VTKJL_LIB"] = joinpath(pwd(), "wrapper", "build", "libvtk_julia.so")
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

The suite (181 tests) includes analytic validations (e.g. clipping a unit hex
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
