# WrapIt spike report — can it generate VTK.jl's bindings?

Date: 2026-10-24 · WrapIt 1.8.0 (`WrapIt_jll`) · CxxWrap 0.17.5 · VTK_jll 9.7.1 · Julia 1.12.6
Artifacts (repro scripts): `gen/wrapit/` (driver), scratch copy of the raw spike in `/tmp/opencode/wrapit_spike` (ephemeral).

## Verdict

**WrapIt is viable as the generator, but only with a permanent companion
layer**: a config driver (input-header selection), a mechanical
post-processor, and a small hand-written shim. It is not "generate-and-forget".
The spike's end-to-end conformance slice — hex mesh → temperature field →
clip → write/read `.vtu`, checked against VTK.jl's analytic oracle — passes
using generated bindings for ~95% of calls.

**Decision: adopt WrapIt + driver + post-processor + shim; do not write a
hand-rolled `vtkWrapJulia`.** The expensive 80% (AST traversal, overload
emission, inheritance mapping, CxxWrap code emission) already works against
VTK_jll. The remaining 20% is enumerable, mostly stable across VTK releases,
and partly upstream-fixable.

## What the spike proved

| Gate | Result |
|---|---|
| Parse VTK 9.7 headers (libclang; artifact include dirs + MPI `mpi.h`) | ✅ 48 headers, ~0.9 s |
| Codegen for the conformance subset | ✅ 63 classes / 1253 methods / 22 enums |
| Compile generated C++ against VTK_jll | ✅ 0 errors (g++ 16, C++17, 9.7k LOC) |
| Load the generated Julia module | ✅ (after ostream/keyword vetoes) |
| End-to-end pipeline vs analytic oracle | ✅ clip = tetrahedron (4 pts, 1 cell); writer → reader round-trip, correct values |

Quantified: the hand-written wrapper is 594 LOC / 86 methods; the WrapIt
module for the subset is 9.3k LOC / 1253 methods. Adding a new filter class
by hand ≈ 30 min; with the driver ≈ 2 min (add 1–2 headers to `input`,
regenerate).

## Pre-spike risk that dissolved: `vtkSmartPointer<T>`

STATUS.md §5 feared custom smart-pointer arguments would sink automation.
They don't, because **VTK's public API returns raw pointers, not smart
pointers**. WrapIt maps raw-pointer returns to *non-owning* `CxxPtr`
(nothing is wrongly `delete`d). The rare smart-pointer returns
(e.g. `vtkDataArray::ToAOSDataArray()`) become by-value parametric
`vtkSmartPointer{T}` objects (compiles and loads; deep usability untested).
Ownership therefore stays in the existing hand-written layer
(`take_ref` + `IsSmartPointerType<vtkSmartPointer>` traits) — orthogonal to
the generator choice.

---

## Bugs found in WrapIt 1.8.0 (upstream report candidates)

### Bug 1 — Silent truncation + exit 0 on macro-generated methods (critical)

**Symptom.** With any input header whose classes use VTK's
`vtkSetMacro` / `vtkGetMacro` / `vtkSetStringMacro` / `vtkBooleanMacro`
accessors, the generated `.cxx` simply *stops* mid-emission — the last line
is a comment with an empty source location:

```cpp
    DEBUG_MSG("Adding wrapper for int vtkAbstractArray::GetNumberOfComponentsMinValue() (" __HERE__ ")");
    // signature to use in the veto list: int vtkAbstractArray::GetNumberOfComponentsMinValue()
    // defined in 
```

All wrapper structs and the module registration function after that point
are missing. **WrapIt then prints full generation statistics and exits 0.**
Observed with both `n_classes_per_file = 0` (single file, ~4 classes
emitted) and `= 1` (JlClasses.cxx truncated); same root cause, so the
"all-in-one truncation" is not a separate bug.

**Repro.** Minimal `wrapit.toml`:

```toml
module_name = "Repro"
input = ["vtkAbstractArray.h"]
include_dirs = ["<VTK_jll artifact>/include/vtk-9.7", "<MPICH_jll artifact>/include"]
cxx-std = "c++17"
```

`vtkAbstractArray.h` triggers it via e.g. `vtkSetMacro(NumberOfComponents, int)`
(first observed victim: `void vtkAbstractArray::SetNumberOfComponents(int)`;
`vtkSetStringMacro(Name)` → `SetName`/`GetName` also trigger it).

**Expected.** Either emit the wrapper (source location should be resolved
to the macro expansion spelling or the class declaration) or skip the
method with a report entry — never truncate the remaining output, and exit
nonzero on emission failure.

**Hypothesis.** The emitter resolves the method's source location via
libclang and, on an invalid/empty expansion location, throws or returns an
error that aborts the per-file emission loop; the outer driver ignores it.

**Scale for VTK.** VTK headers are full of these macros. The spike needed
**207 exact-signature vetoes** for the 48-header conformance subset (~89
boolean accessor quadruplets `Set/Get/XxxOn/XxxOff`, the rest scalar/string
accessors incl. `MinValue`/`MaxValue`).

**Workaround (automated).** Loop: generate → detect the `// defined in \n`
truncation marker → extract the last "signature to use in the veto list:"
line → append to `veto.txt` → regenerate. Converged in ~2 min (~128
iterations). Implemented in `gen/wrapit/build.jl`; committed `veto.txt` is
the converged state so a fresh run does 0 iterations unless the input set
changes.

### Bug 2 — `inheritances` ignored when a single-inheritance parent is unmappable (major)

**Symptom.** VTK's concrete arrays really inherit
`vtkAOSDataArrayTemplate<T>` (e.g. `vtkDoubleArray : vtkAOSDataArrayTemplate<double> : vtkDataArray`).
WrapIt cannot map the template parent, registers `vtkDoubleArray` with **no
Julia base type**, and the config override has no effect:

```toml
inheritances = ["vtkDoubleArray:vtkDataArray"]   # silently ignored
```

The docs say `inheritances` is consulted for classes with *multiple*
inheritance; for single inheritance "the first class of the parent list …
is used". The template parent is dropped before the override is considered.

**Expected.** Consult `inheritances` whenever the parent that would be used
is not mappable (or at least warn).

**Workaround (mechanical post-process).** In the generated `JlClasses.cxx`:
re-point `add_type<vtkDoubleArray>("vtkDoubleArray")` at
`jlcxx::julia_base_type<vtkDataArray>()` and add the CxxWrap trait:

```cpp
namespace jlcxx {
  template<> struct SuperType<vtkDoubleArray> { typedef vtkDataArray type; };
}
```

This is exactly the `__VTK_WRAP__` fake-superclass trick VTK.jl's
hand-written wrapper already uses. 10 lines of Python; classes listed in
one constant. Implemented in `gen/wrapit/build.jl` (`postprocess!`).

### Bug 3 — Generated Julia module exports Julia keywords (minor)

VTK's `std::vector` iterator surface (`begin`, `end`, `assign`, …) is
wrapped and exported, producing an **unparseable** module:

```julia
export ..., begin, end, vtkAbstractArray      # ParseError: invalid identifier
```

**Workaround.** `export_blacklist = ["begin", "end", "assign", ...]`.
**Expected.** WrapIt should never emit Julia keywords (or their `Base.`
escapes) in export statements.

### Bug 4 — `std::basic_ostream` wrapped into uncompilable code (minor)

`PrintSelf(ostream&, vtkIndent)` methods pull `std::basic_ostream` in as a
parametric type; the generated default-construction code hits the
protected `std::basic_ostream` constructor:

```
module.hpp:124:16: error: 'std::basic_ostream<...>::basic_ostream()' is protected within this context
```

plus repeated `Failed to find type declaration of ostream` noise during
generation, and (downstream) CxxWrap load failure
`No appropriate factory for type So` if any `ostream`-typed method
survives (e.g. `PrintValues`).

**Workaround.** Veto the class (`/std::basic_ostream.*/`) and all ostream
methods (`/.*PrintSelf.*/`, `/.*PrintValues.*/`).
**Expected.** WrapIt could auto-skip `std::ostream` args (map to `void` /
skip method) since it already detects the missing declaration.

---

## Integration notes (what the driver does, and why)

All under `gen/wrapit/`:

| File | Role |
|---|---|
| `build.jl` | driver: render config → veto loop → post-process → compile (g++) |
| `wrapit.toml.template` | config; artifact paths rendered at runtime (no machine-specific hashes committed) |
| `veto.txt` | converged veto list (Bug 1 workaround); grows only when `input` changes |
| `shim.cpp` | accessors WrapIt can't generate (string/boolean macros); mirrors the hand wrapper's surface |
| `conformance.jl` | spike CI gate: the analytic-oracle pipeline run against the generated module |
| `Project.toml` | env for the driver (WrapIt_jll, VTK_jll, CxxWrap, ReadVTK) |

Behaviors baked into the driver from spike findings:

1. **Inheritance chain completeness**: every header of every chain in the
   input set (`vtkDataObjectAlgorithm.h`, `vtkXMLDataReader.h`,
   `vtkXMLUnstructuredDataReader.h`, `vtkXMLWriterBase.h`, …). A missing
   link shows up as a Julia-side `MethodError` (broken `CxxPtr` upcast) —
   currently discovered iteratively.
2. **VTK 9 API reality**: generated bindings expose
   `SetInputDataObject` (there is no `SetInputData` on `vtkAlgorithm` —
   the hand wrapper invented that per-filter), `GetVoidPointer(i)` with an
   index, and `InsertNextCell(type, vtkIdList*)`.
3. **Ownership**: generated factory/getter returns are borrowed `CxxPtr`;
   the owning smart-pointer layer remains the hand-written shim (unchanged).

## Suggested next steps

1. Report Bugs 1–4 to [grasph/wrapit](https://github.com/grasph/wrapit)
   (Bug 1 is the one that matters; a fix would delete most of `veto.txt`).
2. Promote `conformance.jl` to a real testset (e.g. run in CI when
   `gen/wrapit` changes) before switching any production path to generated
   bindings.
3. Only then consider generating the full CFD subset into `wrapper/` and
   shrinking the hand-written file to ownership + shim.
