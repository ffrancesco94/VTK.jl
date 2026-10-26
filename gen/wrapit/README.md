# WrapIt driver — the binding generator

Generates the `VTKGen` CxxWrap module from VTK 9.7 headers using
[WrapIt](https://github.com/grasph/wrapit) (via `WrapIt_jll`), merged with a
hand-written shim for accessors WrapIt cannot generate. **This is the
generator behind the shipped `VTK.jl` module**: `gen/build_wrapper.jl` runs
this driver and installs the merged library at
`wrapper/build/libvtk_julia.so` (the default location `src/VTK.jl` loads).
The legacy hand-written CMake wrapper (`gen/build_wrapper_cmake.jl`,
`wrapper/`) remains as a fallback; CI exercises both (A/B via
`ENV["VTKJL_LIB"]`). Full story:
[`docs/wrapit-spike.md`](../../docs/wrapit-spike.md); migration notes:
[`MIGRATION_STATUS.md`](MIGRATION_STATUS.md).

## Usage

```sh
# from the repo root — generate + merge + compile + install (default build)
julia --project=. gen/build_wrapper.jl

# or driver-only (products land in gen/wrapit/build/, gitignored)
julia --project=gen/wrapit -e 'using Pkg; Pkg.instantiate'   # once
julia --project=gen/wrapit gen/wrapit/build.jl

# smoke-test the merged library against the analytic oracle
julia --project=gen/wrapit gen/wrapit/conformance.jl
```

## Files

| file | role |
|---|---|
| `build.jl` | driver: renders `wrapit.toml` from the template (runtime artifact paths), runs the Bug-1 veto loop, audits shim clashes/types, post-processes (AOS re-base, smart-pointer strip, shim injection), compiles the single merged library |
| `wrapit.toml.template` | WrapIt config; `__VTK_INCLUDE__`/`__MPI_INCLUDE__`/`__VETO_LIST__` are substituted by `build.jl` |
| `veto.txt` | converged veto list (WrapIt bug 1 workaround: macro-generated accessors). Grows automatically when `input` changes. The regex lines (`/std::basic_ostream.*/` etc.) are load-bearing — they veto ostream wrappers; do not remove |
| `shim_vtkjl.{h,cpp}` | everything WrapIt can't emit, mechanically extracted from the retired hand wrapper: smart-pointer traits, ownership factories, error window, zero-copy workers, macro accessors, downcasts, `upcast_dataarray` |
| `conformance.jl` | CI gate: unit-hex → temperature → clip (tetrahedron oracle) → write/read `.vtu`, through the merged library via `@wrapmodule` |
| `build/` (gitignored) | generated C++/Julia code and the merged `libvtk_julia.so` |

## Extending the wrapped surface

Add the class's header to `input` in `wrapit.toml.template` **including any
missing intermediate base-class headers** (a broken chain shows up as a
Julia-side `MethodError` on inherited calls), then re-run `build.jl`. New
macro-generated accessors are auto-vetoed; shim clashes are vetoed
mechanically ("REGENERATE" message — run again). Re-provide any accessor you
need in `shim_vtkjl.cpp` (WrapIt bugs are documented in
`docs/wrapit-spike.md`).
