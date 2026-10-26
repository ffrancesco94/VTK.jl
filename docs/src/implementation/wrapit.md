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

`build.jl` renders the WrapIt config with runtime artifact paths, **builds
wrapit from source** (`wrapit_src.jl`, from
[`ffrancesco94/wrapit`](https://github.com/ffrancesco94/wrapit) — our fork
with the macro-truncation fix, PR #1), runs it, generates the mechanical
shim (`auto_shim.jl`), post-processes the generated C++, and compiles **one
merged library** (`gen/wrapit/build/shipped/libvtk_julia.so`, gitignored)
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

The auto-shim skips methods the hand shim already provides (dedup by
class+name) and methods WrapIt already generated (normalized-signature
match), so there are no duplicate registrations; string getters
intentionally override the generated `const char*` versions with
`std::string` ones via the clash audit.

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
| `veto.txt` | small hand-maintained list: ostream wrappers (WrapIt bug 4) and the getters whose ownership the shim overrides. The macro-accessor vetoes are **gone** (bug 1 is fixed in our wrapit fork); clash vetoes are still re-derived mechanically by `veto_shim_clashes!()` when needed |
| post-processor in `build.jl` | Bug 2: AOS leaf arrays' real parent is a template, so their Julia base is re-pointed at `vtkDataArray` with `jlcxx::SuperType` (the same fake-superclass trick as the retired hand wrapper). Also strips WrapIt's parametric `vtkSmartPointer` wrapper (the shim registers the real one) and injects the shim into the module init |
| `veto_shim_clashes!()` / `check_shim_types_registered!()` in `build.jl` | mechanical audits, re-run on every build: generated methods colliding with the shim are vetoed (duplicate Julia methods are fatal at precompile), and every vtk type the shim references must be registered by the generated code |
| `shim_vtkjl.{h,cpp}` | everything that needs a human decision: smart-pointer traits + `add_smart_pointer`, `take_ref`'d getters/outputs, the error window, zero-copy views, **generic `SetInputData`/`GetOutput`/`Update` on `vtkAlgorithm`** (no per-filter plumbing), downcasts, explicit AOS-leaf up-casts (`upcast_dataarray`) |
| `auto_shim.jl` | generates the mechanical shim from the headers: `X_new` factories and macro accessors. Only public members, non-template classes, whitelisted scalar types; dedups against the hand shim and against WrapIt's own output |
| `conformance.jl` | CI gate: loads the merged library directly (`@wrapmodule`, no package needed) and replays the unit-hex → clip (tetrahedron oracle) → write/read `.vtu` pipeline |

Ownership of factory/getter returns stays in the shim layer (`take_ref` +
smart-pointer traits) regardless of generator — the two concerns are
orthogonal by design.

## Extending the wrapped surface

1. Add the class's header — and any missing intermediate base-class headers
   — to `input` in `wrapit.toml.template`.
2. Run `build.jl`; the generator builds wrapit from our fork on first use
   (git + CMake + libclang + OpenSSL headers needed). Shim clashes are
   vetoed mechanically ("added N shim-clash vetoes; REGENERATE" — just run
   it again). **Factories and macro accessors come for free; the generic
   `SetInputData`/`GetOutput` covers every algorithm**, so most new
   filters/readers/writers need no shim edits at all.
3. Only if you need ownership policy, a downcast, or a convenience the
   generator cannot infer, add it to `shim_vtkjl.cpp`.
4. Verify with `conformance.jl`, then with the main test suite (both wrapper
   variants are exercised in CI).

## Upstream bugs (report candidates)

Documented with repros in
[`docs/wrapit-spike.md`](https://github.com/ffrancesco94/VTK.jl/blob/main/docs/wrapit-spike.md)
and issue-ready write-ups in
[`docs/wrapit-upstream-bugs.md`](https://github.com/ffrancesco94/VTK.jl/blob/main/docs/wrapit-upstream-bugs.md):
(1) silent truncation on macro-generated methods; (2) `inheritances`
ignored for template parents; (3) Julia keywords exported; (4)
`std::basic_ostream` wrapped into uncompilable code.
**Bug 1 is fixed and validated**: the 3-line null guard in
`operator<<(CXString)` was merged as
[`ffrancesco94/wrapit#1`](https://github.com/ffrancesco94/wrapit/pull/1),
and the driver now builds wrapit from that fork — the veto loop and the
~200 macro-accessor vetoes are gone. Bugs 2–4 remain (workarounds:
AOS post-processor, `export_blacklist`, ostream vetoes in `veto.txt`).
