# The WrapIt driver

`gen/wrapit/` contains the pipeline that generates the C++ binding module
from VTK headers using [WrapIt](https://github.com/grasph/wrapit) (libclang ->
CxxWrap code), replacing hand-writing of the bulk method surface. **This is
the generator behind the shipped library**: `gen/build_wrapper.jl` drives it
and installs the merged library at `gen/wrapit/build/shipped/libvtk_julia.so`.

The approach follows the same pattern as [Geant4.jl](https://github.com/JuliaHEP/Geant4.jl)
and [ROOT.jl](https://github.com/JuliaHEP/ROOT.jl): WrapIt generates the
C++ bindings from the library headers, a companion shim layer handles
ownership and convenience methods, and the result is distributed as a JLL
binary package [here](https://github.com/JuliaBinaryWrappers/VTK_julia_jll.jl).

## Quick start

```shell
julia --project=. gen/build_wrapper.jl        # generate + merge + compile + install
julia --project=gen/wrapit gen/wrapit/build.jl    # same, without the install step
julia --project=gen/wrapit gen/wrapit/generated_library_integration.jl  # analytic-oracle gate
```

`build.jl` renders the WrapIt config with runtime artifact paths, **builds
[upstream WrapIt](https://github.com/grasph/wrapit) from source**
(`wrapit_src.jl`), runs it, generates the mechanical shim (`auto_shim.jl`),
and produces smart-pointer forwarding overloads
(`smartptr_wrappers.jl` -> `src/generated_methods.jl`), post-processes the
generated C++, and compiles **one merged library**
(`gen/wrapit/build/shipped/libvtk_julia.so`, gitignored)
from:

1. the WrapIt-generated code (~60 classes, 1200+ methods, true VTK
   inheritance),
2. an **auto-generated mechanical shim** (`auto_shim.jl` →
   `build/cxx/shim_auto.cpp`, ~25 methods): owning `X_new` factories
   (detected from `static vtkX* New();`) and gap-filling/string accessors
   derived from the VTK accessor macros,
3. a hand shim (`shim_vtkjl.{h,cpp}`, ~450 lines) merged into the same
   `JLCXX_MODULE` — smart-pointer traits, ownership policy (`take_ref`),
   the error window, zero-copy workers, and **one generic
   `SetInputData`/`GetOutput` for all algorithms** (via
   `vtkAlgorithm::SetInputDataObject`/`GetOutputDataObject`, with downcasts
   in the Julian layer).

The source defaults to upstream `main`. Set `VTKJL_WRAPIT_UPDATE=1` to advance
an existing checkout, or use `VTKJL_WRAPIT_REPO` and `VTKJL_WRAPIT_REF` to select
another repository or a release tag. Changing the configured repository or ref
also triggers a rebuild.

The auto-shim skips methods the hand shim already provides (dedup by
class+name) and methods WrapIt already generated (normalized-signature
match), so there are no duplicate registrations; string getters
intentionally override the generated `const char*` versions with
`std::string` ones via the clash audit.

## The companion layer

| piece | why |
|---|---|
| `VTK.wit.in` | input headers — **every link of every inheritance chain** must be listed or Julia-side upcasts break (`MethodError` on inherited calls) |
| `veto.txt` | small hand-maintained list: ostream wrappers and the getters whose ownership the shim overrides. The macro-accessor vetoes are **gone** (upstream WrapIt no longer truncates macro-generated methods); clash vetoes are still re-derived mechanically by `veto_shim_clashes!()` when needed |
| post-processor in `build.jl` | AOS leaf arrays and other public classes whose direct parent is unmapped are re-pointed at their nearest registered VTK ancestor with `jlcxx::SuperType`. This covers structured data, multiblock datasets/readers/writers, and `vtkIdTypeArray`. Also strips WrapIt's parametric `vtkSmartPointer` wrapper (the shim registers the real one) and injects the shim into the module init |
| `veto_shim_clashes!()` / `check_shim_types_registered!()` in `build.jl` | mechanical audits, re-run on every build: generated methods colliding with the shim are vetoed (duplicate Julia methods are fatal at precompile), and every vtk type the shim references must be registered by the generated code |
| `shim_vtkjl.{h,cpp}` | everything that needs a human decision: smart-pointer traits + `add_smart_pointer`, `take_ref`'d getters/outputs, the error window, zero-copy views, **generic `SetInputData`/`GetOutput`/`Update` on `vtkAlgorithm`** (no per-filter plumbing), downcasts, explicit AOS-leaf up-casts (`upcast_dataarray`) |
| `auto_shim.jl` | generates the mechanical shim from the headers: `X_new` factories and macro accessors. Only public members, non-template classes, whitelisted scalar types; dedups against the hand shim and against WrapIt's own output |
| `smartptr_wrappers.jl` | generates `src/generated_methods.jl` from actual raw-pointer registrations. These Julia overloads accept smart pointers and forward through `_cp`, eliminating explicit conversions at ordinary call sites while retaining the low-level raw-pointer API |
| `generated_library_integration.jl` | Low-level integration test: loads the merged library directly (`@wrapmodule`, no package needed) and replays the unit-hex → clip (tetrahedron oracle) → write/read `.vtu` pipeline |

Ownership of factory/getter returns stays in the shim layer (`take_ref` +
smart-pointer traits).

## Extending the wrapped surface

1. Add the class's header (and any missing intermediate base-class headers) to
   `input` in `VTK.wit.in`.
2. Run `build.jl`; the generator builds upstream WrapIt from source on first
   use (git + CMake + libclang + OpenSSL headers needed). Shim clashes are
   vetoed mechanically ("added N shim-clash vetoes; REGENERATE" —> just run
   it again). **Factories and macro accessors come for free; the generic
   `SetInputData`/`GetOutput` covers every algorithm**, so most new
   filters/readers/writers need no shim edits at all.
3. Only if you need ownership policy, a downcast, or a convenience the
   generator cannot infer, add it to `shim_vtkjl.cpp`.
4. Verify with `generated_library_integration.jl`, then with the main test suite.

## Upstream bugs

Four WrapIt issues were identified while developing the driver:
(1) silent truncation on macro-generated methods; (2) `inheritances`
ignored for template parents; (3) Julia keywords exported; (4)
`std::basic_ostream` wrapped into uncompilable code.
**Bug 1 is fixed and validated upstream**: [issue
#76](https://github.com/grasph/wrapit/issues/76) was closed by commit
[`408e3c1`](https://github.com/grasph/wrapit/commit/408e3c1d6b4c012cc7ac7ec51c0a15d791a29822),
which also added a macro-generation regression test. The driver builds upstream
WrapIt, so the ~200 macro-accessor vetoes are gone. Bugs 2–4 remain
(workarounds: AOS post-processor, `export_blacklist`, ostream vetoes in
`veto.txt`).
