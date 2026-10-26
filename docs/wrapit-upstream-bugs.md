# WrapIt — four upstream bugs, with reproducers and fix suggestions

Audience: [grasph/wrapit](https://github.com/grasph/wrapit) issue reports.
Environment: WrapIt 1.8.0 (`WrapIt_jll`) **and** `main@aff970b` (built from
source against system libclang 22), CxxWrap 0.17.5, VTK_jll 9.7.1, g++,
Linux x86_64. Each section is self-contained and can be pasted as an issue.

TL;DR for VTK.jl: **Bug 1 is fully diagnosed, its fix is validated
(3-line null guard), and the patch is merged as
[`ffrancesco94/wrapit#1`](https://github.com/ffrancesco94/wrapit/pull/1) —
VTK.jl now builds wrapit from that fork, so the veto loop and the ~200
macro-accessor vetoes are gone.** Bugs 2–4 remain open (workarounds below).
Bug 3 is the next-easiest PR; Bug 4 is the least trivial. Our remaining
workarounds live in `gen/wrapit/` (AOS post-processor, `export_blacklist`,
ostream vetoes in `veto.txt`).

---

## Bug 1 — Silent truncation of generated files on macro-generated methods (critical)

**Summary.** When an input class has macro-generated methods (VTK's
`vtkSetMacro`/`vtkGetMacro`/`vtkSetStringMacro`/`vtkBooleanMacro`, …), the
generated `.cxx` stops **mid-line**, right after the method's
`// defined in ` comment. All wrappers for the remaining methods/classes are
silently dropped. WrapIt prints full generation statistics and **exits 0**.

**Root cause (proven).** `src/utils.cpp`:

```cpp
std::ostream& operator<<(std::ostream& stream, const CXString& str){
  stream << clang_getCString(str);   // <- may be NULL
  clang_disposeString(str);
  return stream;
}
```

For a macro-expansion cursor, `operator<<(CXSourceLocation)` (same file)
calls `clang_getSpellingLocation`, which yields a **null `CXFile`**;
`clang_getFileName(file)` then produces a `CXString` whose
`clang_getCString` is **NULL**. Streaming a null `const char*` sets
**badbit** on the stream (libstdc++), so *every subsequent insertion into
the output file is silently discarded*. Generation continues "successfully"
— hence the statistics and exit 0.

Minimal demonstration of the mechanism (independent of WrapIt):

```cpp
std::ofstream o("/tmp/x"); o << "BEFORE\n";
o << (const char*)nullptr; o << "AFTER\n";
// o.bad() == true, file contains only "BEFORE"
```

**Reproducer.** Any VTK header with macro accessors, e.g.:

```toml
module_name = "Repro"
input = ["vtkAbstractArray.h"]
include_dirs = ["<VTK_jll artifact>/include/vtk-9.7", "<MPICH_jll artifact>/include"]
cxx-std = "c++17"
```

`wrapit --force -v 0 wrapit.toml` → `cxx/JlClasses.cxx` ends with (no
trailing newline):

```
    DEBUG_MSG("Adding wrapper for void vtkAbstractArray::SetNumberOfComponents(int) (" __HERE__ ")");
    // signature to use in the veto list: void vtkAbstractArray::SetNumberOfComponents(int)
    // defined in 
```

**Suggested fix (validated).** Null-guard in `operator<<(CXString)`:

```cpp
std::ostream& operator<<(std::ostream& stream, const CXString& str){
  const char* s = clang_getCString(str);
  stream << (s ? s : "");
  clang_disposeString(str);
  return stream;
}
```

Optional hardening on top: check `o.good()` when finalizing each output
file and exit nonzero on stream failure, so no future silent truncation is
possible. Using `clang_getExpansionLocation` (or printing the macro
expansion context) would also make the `// defined in` comments useful for
macro methods.

**Validation of the fix.** Same 48-header VTK input, empty veto list:

| | original binary | patched binary |
|---|---|---|
| `JlClasses.cxx` | **676 lines, truncated mid-line at `// defined in `** | **12 578 lines, complete** |
| macro methods (`SetNumberOfComponents`, `SetInsideOut`, …) | absent | generated normally (`// defined in :70:1` followed by full `t.method(...)` wrappers) |
| exit code / statistics | 0 / full stats | 0 / full stats |

**Impact for VTK.** The 48-header CFD subset needed **~207 exact-signature
vetoes** to route around this bug (macro accessors were removed from the
generated API). With the fix, those methods are generated and the veto loop
becomes unnecessary.

---

## Bug 2 — `inheritances` cannot override an unmappable (template) parent (major)

**Summary.** `vtkDoubleArray` really inherits
`vtkAOSDataArrayTemplate<double>` (which inherits `vtkDataArray`). WrapIt
cannot map the template parent, so `vtkDoubleArray` is registered with **no
Julia base type** — and the documented override has no effect:

```toml
inheritances = ["vtkDoubleArray:vtkDataArray"]   # silently ineffective
```

**Root cause.** `CodeTree::getParentClassesForWrapper` (`src/CodeTree.cpp`)
sets `inheritance_preference` from the config, but in the base-specifier
visitor a parent is only accepted if `isBaseWrapped` (the parent is itself
among `types_`). The configured parent therefore acts only as a *selector
among already-wrapped bases*, never as an override for an unmapped parent.
A template parent is not in `types_`, so `main_parent` stays null and the
only feedback is the late warning
`Inheritance preference vtkDoubleArray:vtkDataArray cannot be fulfilled ...`.

**Reproducer.** Input `vtkDoubleArray.h` + `vtkDataArray.h` (plus their
base-chain headers) with the `inheritances` line above → generated
`add_type<vtkDoubleArray>("vtkDoubleArray")` without a base type, although
`vtkDataArray` **is** wrapped.

**Suggested fix.** In the base-specifier visitor, when
`inheritance_preference` is set and the base's type spelling equals
`preferred_parent`, accept that base as `main_parent` **regardless of
`isBaseWrapped`** (the user explicitly vouches for it; keep/extend the
warning when the preferred parent is not wrapped anywhere else in the
module). ~15 lines. This also composes with the existing rule that skips
`SuperType` emission for template-parameterized parents: the preferred
parent (`vtkDataArray`) is not a template, so `SuperType` is emitted
correctly.

**Expected.** `add_type<vtkDoubleArray>("vtkDoubleArray", jlcxx::julia_base_type<vtkDataArray>())`
plus the matching `jlcxx::SuperType` specialization — i.e. the same
fake-superclass trick VTK itself uses for its wrappers.

**Workaround in VTK.jl.** Mechanical post-processing of the generated code
(`build.jl:postprocess!`, constant `AOS_LEAF_ARRAYS`).

---

## Bug 3 — Generated Julia module exports Julia keywords (minor)

**Summary.** Wrapped `std::vector` iterator surface (`begin`, `end`,
`assign`, …) is exported verbatim, producing an **unparseable** module:

```julia
export ..., begin, end, vtkAbstractArray      # ParseError: invalid identifier
```

**Root cause.** The export loop in `CodeTree.cpp` (module `.jl` writer,
around the `to_export_` iteration) only filters `export_blacklist_`; there
is no reserved-word protection.

**Reproducer.** Any input that wraps `std::vector` iterators (e.g. VTK
headers exposing `vtkIdList`/STL) with `export = "all"` and no blacklist,
then `using Repro` in Julia → `ParseError`.

**Suggested fix.** Maintain a static set of Julia reserved words in the
export writer and skip (or escape) them regardless of the user blacklist:
`begin, end, function, if, else, elseif, for, while, return, break,
continue, do, let, const, global, local, module, baremodule, struct,
mutable, abstract, primitive, type, macro, quote, try, catch, finally,
using, import, export, as, in, isa, where, new, true, false`.
A few lines, no design choices. (Escaping with `var"begin"`/`Base.begin`
would preserve the methods; simply not exporting them is enough for a
first fix.)

**Workaround in VTK.jl.** `export_blacklist = ["begin", "end", "assign",
"copy", "empty", "iterator", "collect"]` in `wrapit.toml.template`.

---

## Bug 4 — `std::basic_ostream` wrapped into uncompilable code (minor/major for VTK)

**Summary.** `PrintSelf(std::ostream&, vtkIndent)`-style methods pull
`std::basic_ostream` in as a parametric type; the generated
default-construction code hits its **protected constructor**:

```
module.hpp:124:16: error: 'std::basic_ostream<...>::basic_ostream()' is protected within this context
```

Generation additionally spams `Failed to find type declaration of ostream`
(`remove_non_builtin_qualifiers`, `src/libclang-ext.cpp`), and if an
`ostream`-typed method survives, CxxWrap fails at module load with
`No appropriate factory for type So`.

**Root cause.** WrapIt detects the missing declaration but still registers
the type and emits construction/casting code for it. IO stream types
should never be default-constructed (they cannot be, by design), and
methods taking them are generally not meaningfully callable from Julia.

**Reproducer.** Input `vtkObjectBase.h` (it includes `<iostream>`, so
`std::ostream` *is* defined and the methods are not auto-skipped) with an
empty veto list → generated code fails to compile as above.

**Suggested fix.** Treat IO-stream types as opaque/unwrappable: skip
`std::basic_ostream`/`std::basic_istream` (and their `std::ostream`/
`std::istream` aliases) at type registration, and auto-skip methods with
such parameter/return types instead of emitting uncompilable code. This is
more involved than Bugs 1–3 because it touches type mapping and
construction policy; a pragmatic first step is to make the already-detected
"missing declaration" case skip the type.

**Workaround in VTK.jl.** Regex veto lines in `gen/wrapit/veto.txt`
(`/std::basic_ostream.*/`, `/.*PrintSelf.*/`, `/.*PrintValues.*/`) plus
exact vetoes for `vtkObjectBase::Print/PrintHeader/PrintTrailer`. **These
are load-bearing**: removing them makes generation emit 2 extra classes /
45 methods and breaks the build (verified).

---

## Suggested PR order

1. **Bug 1** — tiny, self-contained, validated by the A/B run above; biggest
   payoff (deletes the veto loop and restores macro accessors).
2. **Bug 3** — a few lines, no design risk.
3. **Bug 2** — small behavioral change in one function; needs a test with a
   template-parented class.
4. **Bug 4** — needs a decision on IO-stream policy; keep our regex vetoes
   until then.

Local build notes for reproducing our validation setup (system clang 22):
WrapIt `main@aff970b` needed one *unrelated* build fix —
`clang::ElaboratedType` no longer exists in clang 22, so its use in
`CodeTree.cpp` was replaced by the public C-API type spelling (debug output
only; patch `docs/patches/wrapit-clang22-build.patch`). CMake flags used:
`-DCLANG_JLL=ON -DCLANG_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release`.
