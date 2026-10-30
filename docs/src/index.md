# VTK.jl

Julia bindings for a CFD-oriented subset of [VTK](https://vtk.org) 9.7. There is the data model, some common formats for I/O (VTK XML formats, CGNS, EnSight) and some manipulation filters.
It is built on [`VTK_jll`](https://github.com/JuliaBinaryWrappers/VTK_jll.jl)
(binaries) and [`CxxWrap.jl`](https://github.com/JuliaInterop/CxxWrap.jl)
(bindings). At the moment there are is no visualisation pipeline, nor a MPI-aware pipeline.

```julia
using VTK

ug = VTK.read_vtu("case.vtu")
p  = VTK.field_array(VTK.point_data(ug), "p")   # VTKDataArray{Float64}
p[1, 1:10] .= 0.0                                # zero-copy write-through

plane = VTK.plane((0.5, 0, 0), (1, 0, 0))
clipped = VTK.clip(ug, plane)                    # vtkUnstructuredGrid
VTK.write_vtu(clipped, "clipped.vtu")            # zlib-compressed XML
```

## What works

- **Data model**: points, unstructured grids, poly data, image data, with VTK's
inheritance mirrored on the Julia side (`vtkUnstructuredGrid <: vtkPointSet <:
vtkDataSet`).
- **Zero-copy arrays**: typed `VTKDataArray{T}` views of VTK's C++ objects
- **I/O**: `.vtu`/`.vtp` readers and writers, as well as `.vtm`, CGNS and
EnSight; interop with ReadVTK.jl and WriteVTK.jl in both directions.
- **Filters**: clip, slice, cell↔point data conversion, contour, surface
extraction, line probes, plus the plane implicit function.
- **Cells**: VTKBase cell-type registry, iterators, and `MeshCell` conversion
straight into `WriteVTK.vtk_grid`.

## Where to go next

| I want to… | Go to |
|---|---|
| Install and build | [Getting started](getting_started.md) |
| Build a grid from Julia data | [Tutorial: building a mesh](tutorials/mesh.md) |
| Work with fields and arrays | [Tutorial: data arrays](tutorials/arrays.md) |
| Exchange files with the outside world | [Tutorial: I/O](tutorials/io.md) |
| Run filter pipelines | [Tutorial: filters](tutorials/filters.md) |
| Understand how it works | [Implementation notes](implementation/architecture.md) |
| Look up a function | [API reference](reference.md) |

## Status

Early development. The living roadmap is
[`STATUS.md`](https://github.com/ffrancesco94/VTK.jl/blob/main/STATUS.md) in
the repository; the long-term goal is a maintained binding-generation
pipeline ([WrapIt driver](implementation/wrapit.md)) under an idiomatic
Julian layer.
