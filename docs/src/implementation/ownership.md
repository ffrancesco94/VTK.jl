# Memory & ownership

VTK is reference-counted; Julia is garbage-collected. The bridge between
them is the subtlest part of VTK.jl, and the one with a genuine landmine
discovered during development.

## The model

- **Factories and outputs** (`UnstructuredGrid()`, `clip(...)`,
  `read_vtu(...)`) return `vtkSmartPointer{T}` registered as a CxxWrap smart
  pointer. Julia holds one strong reference; when the Julia object is
  collected, the finalizer calls `UnRegister`, and VTK frees the object
  when its count hits zero. GC-stress tests (thousands of allocations with
  survivors) verify this.
- **Getters are borrowed.** `point_data(grid)`, `points(grid)`,
  `field_array_raw(...)` return `take_ref`'d smart pointers: an extra
  `Register` balanced by the Julia finalizer's `UnRegister`. The underlying
  storage stays owned by the grid.
- **Views own through the wrapper.** `data(x)` returns a `VTKDataArray`
  that *holds* the smart pointer as a field; `raw_data(x)` returns a flat
  view derived from it (`vec(wrapper)`). The derivation chain —
  `ReshapedArray → VTKDataArray → SmartPointer` — keeps the C++ object
  alive **structurally**, with no finalizers on views:

```julia
da = VTK.data_array(Float64, 1)
VTK.resize!(da, 4)
v = VTK.raw_data(da.obj)
da = nothing; GC.gc()   # the ONLY owner reference is gone…
v[1]                    # …and v is still valid: it owns a share
```

This is the "wrapper-owns-everything" design. Releasing the C++ object
happens when the *last* wrapper/view chain is collected — through CxxWrap's
standard `SmartPointer` finalizer, i.e. the same baseline mechanism the
package has always relied on.

## ⚠️ Why not attach owner-capturing finalizers to views directly?

An earlier experiment did exactly that (`finalizer(_ -> da, view)`) to save
the wrapper indirection. **It corrupts concurrent pipelines.** Measured on
this codebase: ~25% of test runs failed with heisenbug garbage reads once
C++ objects started dying on Julia's GC finalizer threads while the main
thread was inside VTK algorithms; the failures vanished under
`--gcthreads=1` and were absent with no-op finalizers — proving the trigger
was the *owner capture*, not the extra allocation.

The rule that emerged: **C++ VTK objects must not be destroyed from GC
finalizer threads beyond the baseline rate.** The wrapper-owns design
respects it: views never carry finalizers, the object graph keeps owners
alive, and the only finalizer-driven releases are the standard smart-pointer
ones (factories, outputs, wrappers) — empirically stable across thousands of
test runs. Do not "optimize" the indirection away.

(The full forensics — bisection, the no-op-finalizer control, the
gcthreads experiment — are in the git history of `30a1ea2` and recorded in
`STATUS.md` §4.1/§5.)

## Resize semantics

`resize!` calls VTK's `SetNumberOfTuples`, which may **reallocate**:

1. previously obtained views of the same array dangle — do not use them;
2. the grown region is **not zero-initialized** (VTK hands you allocator
   leftovers) — initialize before whole-array reductions.

Both are VTK behaviors, faithfully surfaced.

## Practical checklist

- `data`/`raw_data` results keep the storage alive — dropping the owner is
  safe.
- Views obtained before `resize!` are dead afterwards.
- Don't reduce over freshly-grown storage before writing it.
- Don't attach your own finalizers to VTK objects or views.
