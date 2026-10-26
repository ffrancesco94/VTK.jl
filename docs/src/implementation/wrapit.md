# The WrapIt driver

`gen/wrapit/` contains the pipeline that generates the C++ binding module
from VTK headers using [WrapIt](https://github.com/grasph/wrapit) (libclang →
CxxWrap code), replacing hand-writing of the bulk method surface. **This is
the generator behind the shipped library**: `gen/build_wrapper.jl` drives it
and installs the merged library at `wrapper/build/libvtk_julia.so`. The
hand-written CMake wrapper (`gen/build_wrapper_cmake.jl`) remains as a
fallback (CI exercises both). See the
[full spike report](https://github.com/ffrancesco94/VTK.jl/blob/main/docs/wrapit-spike.md)
for the WrapIt-vs-custom-generator verdict and the four upstream bugs found.

## Quick start

```shell
julia --project=. gen/build_wrapper.jl        # generate + merge + compile + install
julia --project=gen/wrapit gen/wrapit/build.jl    # same, without the install step
julia --project=gen/wrapit gen/wrapit/conformance.jl  # analytic-oracle gate
```

`build.jl` renders the WrapIt config with runtime artifact paths, runs the
auto-veto loop, post-processes the generated C++, and compiles **one merged
library** (`gen/wrapit/build/shipped/libvtk_julia.so`, gitignored) from:

1. the WrapIt-generated code (~60 classes, 1200+ methods, true VTK
   inheritance), and
2. a hand shim (`shim_vtkjl.{h,cpp}`, ~510 lines) merged into the same
   `JLCXX_MODULE` — smart-pointer traits, ownership factories (`take_ref`),
   the error window, zero-copy workers, and macro accessors WrapIt cannot
   emit.

## Why WrapIt (+ shim), not a custom generator

The spike (2026-10-24) compared WrapIt against writing a `vtkWrapJulia`
generator from scratch. Verdict: **WrapIt + permanent companion layer**.
It already solves AST traversal, `&`/`*` overload pairs, inheritance mapping,
and CxxWrap emission — for the CFD subset it produced 63 classes / 1253
methods / 9.3k LOC of compiling C++ in ~1 s. The pre-spike fear that
`vtkSmartPointer` would sink automation turned out moot: VTK's public API
returns raw pointers, which WrapIt maps to non-owning `CxxPtr`.

## The companion layer

| piece | why |
|---|---|
| `wrapit.toml.template` | input headers — **every link of every inheritance chain** must be listed or Julia-side upcasts break (`MethodError` on inherited calls) |
| `veto.txt` | workaround for upstream Bug 1: WrapIt silently truncates output (exit 0!) on macro-generated methods (`vtkSetMacro`, …); the driver auto-vetoes until generation completes. Contains exact signatures plus load-bearing regex lines (`/std::basic_ostream.*/` et al. — removing them makes generation emit ostream wrappers and breaks the build) |
| post-processor in `build.jl` | Bug 2: AOS leaf arrays' real parent is a template, so their Julia base is re-pointed at `vtkDataArray` with `jlcxx::SuperType` (the same fake-superclass trick as the retired hand wrapper). Also strips WrapIt's parametric `vtkSmartPointer` wrapper (the shim registers the real one) and injects the shim into the module init |
| `veto_shim_clashes!()` / `check_shim_types_registered!()` in `build.jl` | mechanical audits, re-run on every build: generated methods colliding with the shim are vetoed (duplicate Julia methods are fatal at precompile), and every vtk type the shim references must be registered by the generated code |
| `shim_vtkjl.{h,cpp}` | everything WrapIt cannot emit: smart-pointer traits + `add_smart_pointer`, `take_ref`'d getters/outputs, `_new` factories, the error window, zero-copy views, string/boolean macro accessors (`SetFileName`, `SetInsideOut`, …), downcasts, explicit AOS-leaf up-casts (`upcast_dataarray`) |
| `conformance.jl` | CI gate: loads the merged library directly (`@wrapmodule`, no package needed) and replays the unit-hex → clip (tetrahedron oracle) → write/read `.vtu` pipeline |

Ownership of factory/getter returns stays in the shim layer (`take_ref` +
smart-pointer traits) regardless of generator — the two concerns are
orthogonal by design.

## Extending the wrapped surface

1. Add the class's header — and any missing intermediate base-class headers
   — to `input` in `wrapit.toml.template`.
2. Run `build.jl`; new macro-generated accessors are auto-vetoed
   (watch for "vetoed (WrapIt bug 1)" lines) and shim clashes are detected
   mechanically ("added N shim-clash vetoes; REGENERATE" — just run it again).
3. If an accessor you need got vetoed, add it to `shim_vtkjl.cpp`.
4. Verify with `conformance.jl`, then with the main test suite (both wrapper
   variants are exercised in CI).

## Upstream bugs (report candidates)

Documented with repros in
[`docs/wrapit-spike.md`](https://github.com/ffrancesco94/VTK.jl/blob/main/docs/wrapit-spike.md):
(1) silent truncation on macro-generated methods — the one that matters;
(2) `inheritances` ignored for template parents; (3) Julia keywords
exported; (4) `std::basic_ostream` wrapped into uncompilable code.
