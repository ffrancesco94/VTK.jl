# Extending the bindings: wrapping a new VTK class

This guide walks through adding a VTK class to VTK.jl **by hand** — no AI
required. It covers the three layers of the pipeline (see
[Architecture](architecture.md) and the ELI5 in the repo root) and the
build/test cycle. We use a concrete example: wrapping `vtkGradientFilter`,
a CFD-useful filter we have not bound yet.

## The pipeline in one picture

```
VTK headers (VTK_jll)                what you edit
        │                            ┌──────────────────────────────┐
        ▼                            │ 1. gen/wrapit/wrapit.toml.template │
   ┌─────────┐  generates  ┌──────────────┐  merges  ┌────────────────┐
   │ WrapIt  │ ──────────► │ JlClasses.cxx│ ◄─────── │ shim_vtkjl.cpp │
   │ (fork)  │   ~95%      │  (generated) │          │  (hand-written)│
   └─────────┘             └──────────────┘          └────────────────┘
        │                            │                      auto_shim.jl
        ▼                            ▼                    (generated shim)
   one libvtk_julia.so  ◄── 2. gen/build_wrapper.jl
        │
        ▼                            ┌──────────────────────────────┐
   @wrapmodule at `using VTK`  ◄─── │ 3. src/*.jl (Julian layer)   │
                                    └──────────────────────────────┘
```

**Rule of thumb:** WrapIt handles the boring 95% (type registration, plain
methods). You only hand-write what a generator cannot infer: ownership
policy, macro-generated API that is invisible to the C++ AST, zero-copy
tricks, and ergonomic adapters.

## Step 0 — prerequisites

Same as the normal build (see the README): git, CMake, a C++17 compiler,
libclang + OpenSSL dev headers, and the Julia project instantiated. You do
**not** need a local VTK build — headers and libraries come from `VTK_jll`.

## Step 1 — tell WrapIt about the class

Add the class's header to the `input` list in
`gen/wrapit/wrapit.toml.template`:

```toml
input = [
  ...
  "vtkDataSetAlgorithm.h",
  "vtkGradientFilter.h",   # <-- new
]
```

Notes:

- **Include the full inheritance chain** if the new class's bases are not
  already listed. WrapIt registers a class under its direct base with
  `julia_base_type<...>`; if the base is missing you get a compile error
  naming it — just add that header too.
- If WrapIt drops a *template* base (e.g. `vtkStructuredData`, or
  `vtkAOSDataArrayTemplate<T>` for the leaf arrays), the driver re-points
  the class in `postprocess!()` in `gen/wrapit/build.jl` — follow the
  existing `vtkStructuredGrid` / `AOS_LEAF_ARRAYS` examples there.
- Methods you do **not** want can be vetoed: add their
  `// signature to use in the veto list:` line from the generated
  `JlClasses.cxx` to `gen/wrapit/veto.txt`.

## Step 2 — build and inspect

```sh
julia --project=. gen/build_wrapper.jl
```

The driver: renders the config → builds/runs wrapit → generates the
auto-shim → self-heals shim/generator clashes via `veto_shim_clashes!()`
(watch for "added N shim-clash vetoes; REGENERATE" — it reruns itself and
converges) → post-processes → compiles one `libvtk_julia.so` and installs
it at `wrapper/build/`.

Then inspect what you got (this is the key skill — read the generated code):

```sh
# Did the class get registered? With which base?
grep -n 'add_type<vtkGradientFilter>' gen/wrapit/build/cxx/JlClasses.cxx

# Which methods came along?
grep -n 'method("' gen/wrapit/build/cxx/JlClasses.cxx | grep -i gradient
```

## Step 3 — decide what the shim must add

Ask three questions:

1. **Does the class have macro-generated setters/getters or a `New()`
   factory?** The auto-shim (`auto_shim.jl`) already emits `X_new` and
   `SetFoo`/`GetFoo` for `vtkSetMacro`/`vtkGetMacro`/string/boolean/vector
   macros — check `build/cxx/shim_auto.cpp`. If it is there, nothing to do.
2. **Does any method return a pointer whose ownership Julia must manage?**
   Factories and `GetOutput()` → return `vtkSmartPointer<T>` (see
   `X_new` in the shim). Borrowed getters → `take_ref<T>(raw)` (see
   `GetPointData`). Getting this wrong = crashes or leaks.
3. **Is the raw API ergonomic enough?** VTK often takes `(i, x, y, z)` or
   fills an output argument; Julia wants tuples and returned values. Add a
   convenience overload in the shim (see `GetPoint` returning a tuple).

For `vtkGradientFilter`, the auto-shim gives us `GradientFilter_new` and
the macro setters (`SetComputeGradient`, …) for free. We only add a
convenience wrapper if we want nicer argument order — optional.

## Step 4 — Julian layer

Add the friendly function to `src/filters.jl` (or `dataset.jl` for I/O):

```julia
"""
    gradient(grid; scalars) -> vtkUnstructuredGrid
"""
function gradient(grid; scalars = nothing)
    f = GradientFilter_new()
    SetInputData(_cp(vtkAlgorithm, f), _cp(vtkDataObject, grid))
    scalars === nothing || SetInputScalars(
        _cp(vtkGradientFilter, f), 0, String(scalars))  # check the generated name
    update!(f)
    return UnstructuredGrid(GetOutput(_cp(vtkAlgorithm, f)))
end
```

Idioms you will reuse constantly:

- `_cp(vtkBaseClass, obj)` — up-cast a smart pointer to the base class the
  C++ method expects (`_cp` = CxxPtr of).
- `update!(algo)` — calls `Update` and throws if VTK reported an error.
- `UnstructuredGrid(GetOutput(...))` — downcast the generic output to the
  concrete type (see `DOWNCAST_REGISTRY` in `src/dataset.jl`; add your type
  there if it is new).

## Step 5 — test

Add a testset to `test/filters.jl` (or a new file + `include` in
`test/runtests.jl`). Two kinds of checks, cheapest first:

1. **Smoke**: the call runs, output has expected type/point count.
2. **Oracle**: verify the numbers against an analytic or independent
   result — e.g. gradient of a linear field is constant. For I/O, cross-check
   against ReadVTK.jl/WriteVTK.jl (see `test/oracle.jl`).

Then:

```sh
rm -rf ~/.julia/compiled/v1.12/VTK   # precompile cache ignores VTKJL_LIB!
julia --project=test test/runtests.jl
```

Expect the full suite green (count grows by your new tests). Also verify the
hand-written fallback still builds and passes — it lags the merged lib, so
new generated-only tests must self-skip:

```julia
@testset "my new feature" begin
    if !isdefined(VTK, :GradientFilter_new)
        @info "not present (hand-written wrapper) — skipping"
        return
    end
    ...
end
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `shim references types the generated module does not register: vtkX` | Add `vtkX.h` to the `input` list (reader/writer headers alone do not register their data types). |
| C++ compile error: `no member named ...` in generated code | A method's parameter type was not registered; add that class's header, or veto the method. |
| `added N shim-clash vetoes; REGENERATE` | Normal: the driver found methods both it and the shim emit; it reruns itself. Only investigate if it does not converge. |
| Julia `MethodError` for a wrapped method | The generated overload was vetoed, or the argument needs an up-cast (`_cp`). Grep `JlClasses.cxx` for the exact signature. |
| Tests pass locally but CI fails | CI builds wrapit from source with a different libclang; check the CLANG_PREFIX notes in `AGENTS.md`. |
| Wrong library loaded after switching | `rm -rf ~/.julia/compiled/v1.12/VTK` — the precompile cache does not track which `.so` was used. |

## When *not* to extend the shim

If the class is plain C++ (no macros, no ownership subtleties, no
convenience needed), **config + Julian layer is enough** — that is the whole
point of the generator. The shim is only for what WrapIt cannot express.
