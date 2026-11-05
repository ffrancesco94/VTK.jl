# VTK.jl

Julia bindings for a CFD-data-oriented subset of [VTK](https://vtk.org) 9.7:
data model, XML I/O, I/O for stuff like EnSight and CGNS and manipulation
filters (clip, slice, cell↔point data conversion, contour, surface extraction).
There is no rendering and no MPI-aware API as of now.

Status: early development. Built on `VTK_jll` (binaries) + `CxxWrap.jl`
(bindings). The C++ wrapper is WrapIt-generated + some manual shims,
distributed as `VTK_julia_jll`. The wrapping pipeline follows the same
approach as [Geant4.jl](https://github.com/JuliaHEP/Geant4.jl) and
[ROOT.jl](https://github.com/JuliaHEP/ROOT.jl). CI tests on Julia 1.11–1.13.

## Installation

The package is not registered in General yet. Install directly from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/ffrancesco94/VTK.jl")
```

The C++ binding module (`libvtk_julia`) comes pre-built via `VTK_julia_jll`
for supported platforms.

### C++ wrapper development

To modify the C++ wrapper, build it from source (requires C++17, CMake,
libclang, OpenSSL):

```sh
julia --project=. gen/build_wrapper.jl
```

This drives the WrapIt-based generator ([`gen/wrapit`](gen/wrapit)): clones and
builds [our wrapit fork](https://github.com/ffrancesco94/wrapit) from source
(needs `git` + network), generates CxxWrap bindings from VTK headers plus a
mechanical shim, merges the hand-written parts, compiles, and installs to
`wrapper/build/libvtk_julia.so`.

There is plumbing to inject a local build of `libvtk_julia.so` by using the
`VTKJL_LIB` env variable. The precompile cache does not track this variable, so
it needs manual clearing after switching (`rm -rf ~/.julia/compiled/v1.*/VTK`).

## Usage

See the documentation.

## Testing

```sh
julia -e 'using Pkg; Pkg.test("VTK")'
```

Tests include analytic checks (clip of a unit hex against a plane yields the
tetrahedron x+y+z ≤ 1) and cross-validation against ReadVTK.jl/WriteVTK.jl,
independent pure-Julia VTK readers/writers.

## Documentation

The documentation (tutorials, implementation notes, API reference) is built
with [DocumenterVitepress.jl](https://github.com/LuxDL/DocumenterVitepress.jl):

```sh
julia --project=docs docs/make.jl
```

