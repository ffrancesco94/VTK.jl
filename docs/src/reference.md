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

```@autodocs
Modules = [VTK]
```
