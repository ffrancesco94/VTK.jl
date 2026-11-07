# WrapIt driver — the binding generator

Generates the `VTKGen` CxxWrap module from VTK 9.7 headers using
[upstream WrapIt](https://github.com/grasph/wrapit), **built from source**,
and merged with a hand-written shim for everything a generator cannot infer.
**This is the generator behind the library shipped in `VTK_julia_jll`**: `gen/build_wrapper.jl` runs this driver
and installs a development build at `wrapper/build/libvtk_julia.so`; select it
with `VTKJL_LIB` instead of the default JLL artifact. Migration notes:
[`MIGRATION_STATUS.md`](MIGRATION_STATUS.md).

Requirements: git, CMake, a C++17 compiler, libclang dev headers + resource
dir, and OpenSSL dev headers (Debian/Ubuntu:
`sudo apt-get install g++ cmake git libclang-dev clang libssl-dev`).

## Usage

```sh
# from the repo root — generate + merge + compile + install (default build)
julia --project=. gen/build_wrapper.jl

# or driver-only (products land in gen/wrapit/build/, gitignored)
julia --project=gen/wrapit -e 'using Pkg; Pkg.instantiate'   # once
julia --project=gen/wrapit gen/wrapit/build.jl

# smoke-test the merged library against the analytic oracle
julia --project=gen/wrapit gen/wrapit/generated_library_integration.jl
```

## Files

| file | role |
|---|---|
| `build.jl` | driver: renders `wrapit.toml` from the template (runtime artifact paths), builds wrapit from source (`wrapit_src.jl`), generates, audits shim clashes/types, post-processes (AOS re-base, smart-pointer strip, shim injection), compiles the single merged library |
| `wrapit_src.jl` | clones and builds upstream [`grasph/wrapit`](https://github.com/grasph/wrapit) into `build/wrapit-build/wrapit`. Update to the latest ref with `VTKJL_WRAPIT_UPDATE=1`; override repo/ref with `VTKJL_WRAPIT_REPO`/`VTKJL_WRAPIT_REF`. Changing the configured repo/ref also triggers a rebuild |
| `VTK.wit.in` | WrapIt config; `__VTK_INCLUDE__`/`__MPI_INCLUDE__`/`__VETO_LIST__` are substituted by `build.jl` |
| `veto.txt` | small hand-maintained list: ostream wrappers (bug 4) and ownership-overridden getters. The ~200 macro-accessor vetoes and the macro-truncation workaround are **gone** (Bug 1 fixed upstream); clash vetoes are re-derived mechanically when needed |
| `auto_shim.jl` | generates the mechanical shim (`build/cxx/shim_auto.cpp`) from the headers: owning `X_new` factories (from `static vtkX* New();`) and macro accessors. Only public members of non-template classes, whitelisted scalar types; dedups against hand shim and WrapIt's own output |
| `smartptr_wrappers.jl` | generates `src/generated_methods.jl`: Julia overloads that accept CxxWrap smart pointers and forward through `_cp` to the raw-pointer bindings. It reads the actual WrapIt/hand-shim/auto-shim registrations, so new methods get forwarding overloads automatically |
| `shim_vtkjl.{h,cpp}` | the decisions a generator can't make: smart-pointer traits, ownership (`take_ref`), error window, zero-copy workers, **generic `SetInputData`/`GetOutput`/`Update` on `vtkAlgorithm`** (no per-filter plumbing), downcasts, `upcast_dataarray` |
| `generated_library_integration.jl` | Low-level integration test: unit-hex → temperature → clip (tetrahedron oracle) → write/read `.vtu`, through the merged library via `@wrapmodule` |
| `build/` (gitignored) | generated C++/Julia code and the merged `libvtk_julia.so` |

## Extending the wrapped surface

Add the class's header to `input` in `VTK.wit.in` **including any
missing intermediate base-class headers** (a broken chain shows up as a
Julia-side `MethodError` on inherited calls), then re-run `build.jl`.
Shim clashes are vetoed mechanically ("REGENERATE" message — run again).
**Factories, macro accessors and `SetInputData`/`GetOutput` come for free**,
so most new filters/readers/writers need no shim edits; only add ownership
policy, downcasts or special conveniences to `shim_vtkjl.cpp`.
