# The WrapIt driver (experimental)

`gen/wrapit/` contains an experimental pipeline that generates the C++
binding module from VTK headers using
[WrapIt](https://github.com/grasph/wrapit) (libclang → CxxWrap code),
replacing hand-writing of the bulk method surface.

::: warning Experimental
The shipped `VTK.jl` module still uses the hand-written
`wrapper/src/vtk_julia.cpp`. The WrapIt driver is the automation spike's
deliverable and CI gate; see the
[full spike report](https://github.com/ffrancesco94/VTK.jl/blob/main/docs/wrapit-spike.md)
for the verdict and the four upstream bugs found.
:::

## Quick start

```shell
julia --project=gen/wrapit -e 'using Pkg; Pkg.instantiate'   # once
julia --project=gen/wrapit gen/wrapit/build.jl               # generate + compile
julia --project=gen/wrapit gen/wrapit/conformance.jl         # analytic-oracle gate
```

`build.jl` renders the WrapIt config with runtime artifact paths, runs the
auto-veto loop, post-processes the generated C++, and compiles the module
plus a small shim into `gen/wrapit/build/` (gitignored).

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
| `wrapit.toml.template` | 48 input headers — **every link of every inheritance chain** must be listed or Julia-side upcasts break (`MethodError` on inherited calls) |
| `veto.txt` | workaround for upstream Bug 1: WrapIt silently truncates output (exit 0!) on macro-generated methods (`vtkSetMacro`, …); the driver auto-vetoes until generation completes |
| post-processor in `build.jl` | workaround for Bug 2: AOS leaf arrays' real parent is a template, so their Julia base is re-pointed at `vtkDataArray` with `jlcxx::SuperType` (the same fake-superclass trick as the hand wrapper) |
| `shim.cpp` (~25 LOC) | accessors WrapIt cannot emit: string/boolean macros (`SetName`, `SetFileName`, `SetInsideOut`, …) |
| `conformance.jl` | CI gate: unit-hex → clip (tetrahedron oracle) → write/read `.vtu`, all through generated bindings |

Ownership of factory/getter returns stays in the hand-written layer
(`take_ref` + smart-pointer traits) regardless of generator — the two
concerns are orthogonal by design.

## Extending the wrapped surface

1. Add the class's header — and any missing intermediate base-class headers
   — to `input` in `wrapit.toml.template`.
2. Run `build.jl`; new macro-generated accessors are auto-vetoed
   (watch for "vetoed (WrapIt bug 1)" lines).
3. If an accessor you need got vetoed, add it to `shim.cpp`.
4. Verify with `conformance.jl`, then with the main test suite.

## Upstream bugs (report candidates)

Documented with repros in
[`docs/wrapit-spike.md`](https://github.com/ffrancesco94/VTK.jl/blob/main/docs/wrapit-spike.md):
(1) silent truncation on macro-generated methods — the one that matters;
(2) `inheritances` ignored for template parents; (3) Julia keywords
exported; (4) `std::basic_ostream` wrapped into uncompilable code.
