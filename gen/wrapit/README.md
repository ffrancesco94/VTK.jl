# WrapIt driver — experimental binding generator

Generates the `VTKGen` CxxWrap module from VTK 9.7 headers using
[WrapIt](https://github.com/grasph/wrapit) (via `WrapIt_jll`), plus a small
hand-written shim for accessors WrapIt cannot generate. This is **not** the
generator used by the shipped `VTK.jl` module (that remains the hand-written
`wrapper/`); it is the automation spike's deliverable and future replacement
candidate. Full story: [`docs/wrapit-spike.md`](../../docs/wrapit-spike.md).

## Usage

```sh
# one-time: instantiate the driver environment
julia --project=gen/wrapit -e 'using Pkg; Pkg.instantiate'

# generate + post-process + compile (into gen/wrapit/build/, gitignored)
julia --project=gen/wrapit gen/wrapit/build.jl

# smoke-test the generated module against the analytic oracle
julia --project=gen/wrapit gen/wrapit/conformance.jl
```

## Files

| file | role |
|---|---|
| `build.jl` | driver: renders `wrapit.toml` from the template (runtime artifact paths), runs the Bug-1 veto loop, post-processes, compiles with g++ |
| `wrapit.toml.template` | WrapIt config; `__VTK_INCLUDE__`/`__MPI_INCLUDE__`/`__VETO_LIST__` are substituted by `build.jl` |
| `veto.txt` | converged veto list (WrapIt bug 1 workaround: macro-generated accessors). Grows automatically when `input` changes |
| `shim.cpp` | accessors WrapIt can't emit (`SetName`/`GetName`, `SetFileName`, `SetInsideOut`, …) — mirrors `wrapper/src/vtk_julia.cpp` |
| `conformance.jl` | CI gate: unit-hex → temperature → clip (tetrahedron oracle) → write/read `.vtu`, all via generated bindings |
| `build/` (gitignored) | generated C++/Julia code and compiled `.so`s |

## Extending the wrapped surface

Add the class's header to `input` in `wrapit.toml.template` **including any
missing intermediate base-class headers** (a broken chain shows up as a
Julia-side `MethodError` on inherited calls), then re-run `build.jl`. New
macro-generated accessors are auto-vetoed; re-provide them in `shim.cpp` if
needed (WrapIt bugs are documented in `docs/wrapit-spike.md`).
