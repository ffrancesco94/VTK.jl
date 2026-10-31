# VTK.jl

Julia bindings for a CFD-oriented subset of [VTK](https://vtk.org) 9.7: data
model, XML I/O, and manipulation filters (clip, slice, cell↔point data
conversion, contour, surface extraction). There is no rendering and no
MPI-aware API as of now.

Status: early development. Built on `VTK_jll` (binaries) + `CxxWrap.jl`
(bindings). The C++ wrapper is WrapIt-generated + some manual shims,
distributed as `VTK_julia_jll`. The wrapping pipeline follows the same
approach as [Geant4.jl](https://github.com/JuliaHEP/Geant4.jl) and
[ROOT.jl](https://github.com/JuliaHEP/ROOT.jl). CI tests on Julia 1.11 and 1.12.

## Installation

The package is not registered in General yet. Install directly from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/ffrancesco94/VTK.jl")
```

The C++ binding module (`libvtk_julia`) comes pre-built via `VTK_julia_jll`
for supported platforms.

### Local development

For development, build the wrapper from source (requires C++17, CMake,
libclang, OpenSSL):

```sh
julia --project=. gen/build_wrapper.jl
```

This drives the WrapIt-based generator ([`gen/wrapit`](gen/wrapit)): clones
and builds [our wrapit fork](https://github.com/ffrancesco94/wrapit) from
source (needs `git` + network), generates CxxWrap bindings from VTK headers
plus a mechanical shim, merges the hand shim, compiles, and installs to
`gen/wrapit/build/shipped/libvtk_julia.so`.

Override the loaded library with `VTKJL_LIB`. The precompile cache does not
track this variable, so it needs manual clearing after switching (`rm -rf
~/.julia/compiled/v1.*/VTK`).

## Usage

See the documentation.

## Design notes

- **Ownership**: factories and outputs return `vtkSmartPointer{T}`, registered
with CxxWrap as a smart pointer; Julia finalizers release references. Borrowed
raw pointers are never exposed in the public API.
- **vtkDataArray**: zero-copy views of the VTK objects are exposed via
`raw_data`/`data` (component-fastest layout, i.e. `(ncomp, ntuples)`
column-major). Views are derived from an owning `VTKDataArray` wrapper
("wrapper-owns-everything"), so they stay valid even if the dataset or original
handle is dropped. After `resize!`, previously obtained views are invalidated
by reallocation.
- **Cell types**: the cell vocabulary is VTKBase's `VTKCellTypes` registry
(shared with ReadVTK/WriteVTK); `cell`/`cells`/`eachcell` return VTKBase
`MeshCell`s with 1-based connectivity, directly consumable by
`WriteVTK.vtk_grid`.
- **Type hierarchy**: wrapped types mirror the VTK inheritance chain, so
`vtkUnstructuredGrid <: vtkPointSet <: vtkDataSet` etc. on the Julia side.
- **Error handling**: `update!` (used by all high-level filter calls) throws if
VTK reported any error during execution.

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

