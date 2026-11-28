# API reference

The supported high-level API is documented below. Generated raw VTK methods
remain lower-level bindings and do not acquire the high-level ownership and
diagnostics guarantees merely because they are registered.

Particle tracing is quarantined under `VTK.Experimental.particle_tracer`. Its
execution path is unsupported until the static-grid crash and temporal
pipeline behavior have been validated; use `stream_tracer` for static fields.

```@docs
VTK.Experimental.particle_tracer
```

```@docs
VTK.data_array
VTK.point_data
VTK.cell_data
VTK.field_data
vtk.UnstructuredGrid
VTK.PolyData 
VTK.Reader 
VTK.Writer 
VTK.Pipeline 
VTK.data 
VTK.raw_data 
VTK.field_array 
VTK.set_array!
VTK.activate!
VTK.active_array
VTK.npoints 
VTK.ncells 
VTK.coordinates 
VTK.bounds 
VTK.center 
VTK.dimensions 
VTK.extent 
VTK.origin
VTK.spacing 
VTK.direction
VTK.array_range
```
