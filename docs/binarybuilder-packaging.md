# BinaryBuilder packaging status and next steps

This note records the ongoing `VTK_julia_jll` packaging work so it can be
resumed from another checkout or machine.

## Approach

We are following the Geant4.jl model:

1. Generate and post-process the WrapIt C++ sources with VTK.jl's normal
   development driver.
2. Store the generated sources and shims in a separate `VTK_cxxwrap` source
   repository.
3. Have BinaryBuilder compile those sources; it does **not** run WrapIt.
4. Keep `VTKJL_LIB` as a development override after the JLL becomes the
   default library.

The current VTK coverage is sufficient for an initial binary release; adding
more wrappers is not a packaging prerequisite.

## Current local layout

The following files live outside the VTK.jl repository on the original
machine:

```text
/home/fra/vtk.jl/packaging/
├── Project.toml / Manifest.toml   # BinaryBuilder, local VTK_julia_jll, VTK_jll
├── build_tarballs.jl
├── VTK_cxxwrap/
│   ├── CMakeLists.txt
│   ├── LICENSE
│   └── src/
│       ├── cpp/
│       │   ├── JlClasses.cxx
│       │   ├── Wrapper.h
│       │   ├── dbg_msg.h
│       │   ├── jlVTKGen.cxx
│       │   ├── jlVTKGen.h
│       │   ├── shim_auto.cpp
│       │   ├── shim_vtkjl.cpp
│       │   └── shim_vtkjl.h
│       └── jl/VTKGen.jl
└── products/
```

`VTK_cxxwrap` contains post-processed generated sources, not the raw output
of WrapIt. The main VTK.jl repository remains the source of truth for
regeneration.

## What works

- Podman in Docker compatibility mode successfully runs the BinaryBuilder
  sandbox.
- A single-platform `x86_64-linux-gnu` build works with GCC 11 and the
  `julia_version=1.12.0` tag.
- CMake finds `VTK_jll`, `libcxxwrap_julia_jll`, and `libjulia_jll` through
  BinaryBuilder's dependency environment.
- The artifact and log tarballs are produced successfully.
- The artifact passes all **180 VTK.jl tests**.
- A local `VTK_julia_jll` was deployed under `~/.julia/dev/VTK_julia_jll`.
- Loading through the JLL also passes all tests after explicitly preloading
  the linked VTK component libraries.

The CGNS and legacy-reader messages about nonexistent files are expected
negative tests, not failures.

## Current recipe essentials

The local `build_tarballs.jl` currently uses:

```julia
sources = [DirectorySource("./VTK_cxxwrap")]
```

and builds only:

```julia
platform = Platform("x86_64", "linux")
platform["julia_version"] = "1.12.0"
platforms = [platform]
```

Products and dependencies:

```julia
products = [
    LibraryProduct("libvtk_julia", :libvtk_julia; dont_dlopen=true),
    FileProduct("VTKGen.jl", :VTKGen_exports),
]

dependencies = [
    BuildDependency("libjulia_jll"),
    Dependency("libcxxwrap_julia_jll"; compat="0.14.12"),
    Dependency("VTK_jll"; compat="9.7.1"),
]
```

The CMake source is `${WORKSPACE}/srcdir`, because `DirectorySource` copies
the directory contents rather than creating a `VTK_cxxwrap` subdirectory.

The build requests `preferred_gcc_version=v"11"`; the sandbox's baseline GCC
4.8.5 is not sufficient for this C++17 codebase.

## Runtime loading: important detail

A manually built wrapper previously found VTK libraries because the local
build embedded VTK_jll's absolute artifact directory in its RPATH. A
relocatable BinaryBuilder artifact cannot use that machine-specific path.

The generated JLL initially failed while eagerly loading `libvtk_julia`:

```text
libvtkIOCGNSReader-9.7.so.1: cannot open shared object file
```

Two changes are therefore needed:

1. Declare the library product with `dont_dlopen=true`, so `using
   VTK_julia_jll` exposes its path without loading it prematurely.
2. In VTK.jl, load the linked VTK component libraries with
   `Libdl.RTLD_GLOBAL` both before `@wrapmodule` (which inspects the library
   during precompilation) and in `__init__` before `@initcxx`. Precompilation
   does not preserve `dlopen` state when a cached module is restored in a
   fresh process.

The preload loop in `src/VTK.jl` uses `Libdl.dlext` and VTK's unversioned
library symlinks rather than hard-coding Linux `.so.1` filenames. It must
still be validated on non-Linux targets as the platform matrix expands.
`LD_LIBRARY_PATH` was used only as a temporary diagnostic workaround and is
not part of the intended user setup.

## Next steps

### 1. Publish `VTK_cxxwrap`

On the original machine, unless already done:

```sh
cd /home/fra/vtk.jl/packaging/VTK_cxxwrap
git init -b main
git add CMakeLists.txt LICENSE src
git commit -m "Add VTK.jl generated wrapper sources"
gh repo create ffrancesco94/VTK_cxxwrap \
    --public --source=. --remote=origin --push
git rev-parse HEAD
```

Record the full commit SHA.

### 2. Build from the published source

Replace `DirectorySource` in `build_tarballs.jl` with a commit-pinned source:

```julia
sources = [
    GitSource("https://github.com/ffrancesco94/VTK_cxxwrap.git",
              "<full-commit-sha>"),
]
```

Rebuild, deploy locally, and rerun the 180 tests to ensure the published
source bundle is complete.

### 3. Validate portable runtime loading

- Preserve the existing MPI preload before loading VTK components.
- Keep component loading ahead of both `@wrapmodule` and `@initcxx`.
- Test without `LD_LIBRARY_PATH` in fresh processes on each supported OS.
- Avoid absolute RPATHs to artifact directories.

### 4. Add reproducibility tooling

Add a documented export/regeneration procedure that copies the required
post-processed files from VTK.jl into `VTK_cxxwrap`. Ideally, CI should
regenerate with pinned VTK/WrapIt versions and fail if the published source
bundle is stale. Record the VTK, WrapIt, generator, and source revisions in
`VTK_cxxwrap`.

### 5. Integrate the JLL into VTK.jl — completed 2026-11-05

- `VTK_julia_jll` is the default source of `libvtk_julia`.
- Local generated builds remain available for development through `VTKJL_LIB`.
- CI and documentation builds use the JLL without a local C++ toolchain.
- The full 180-test suite passes with the published JLL artifacts on Julia
  1.11.9, 1.12.7, and 1.13.2.

### 6. Expand and submit

- Extend the recipe to the desired Julia versions and platforms supported by
  VTK_jll/libjulia (VTK_jll has no Windows build).
- Run the full BinaryBuilder matrix and test representative artifacts.
- Submit the commit-pinned recipe to Yggdrasil.
- After registration, switch VTK.jl's default loading to the registered JLL
  and update `STATUS.md`.

## Useful validation commands

Build and deploy locally:

```sh
cd /home/fra/vtk.jl/packaging
julia --project=. build_tarballs.jl --verbose --deploy=local
```

After integrating portable preloads, test the JLL library without
`LD_LIBRARY_PATH` by setting `VTKJL_LIB` to the path printed by:

```sh
julia --project=/home/fra/vtk.jl/packaging -e \
    'using VTK_julia_jll; println(VTK_julia_jll.libvtk_julia)'
```

Remember to clear VTK's precompile cache when changing wrapper libraries:

```sh
rm -rf ~/.julia/compiled/v1.12/VTK
cd /home/fra/vtk.jl/VTK.jl
julia --project=test test/runtests.jl
```
