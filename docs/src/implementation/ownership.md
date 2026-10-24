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
- **Zero-copy views borrow the storage.** `data`/`raw_data`/the typed
  wrapper's view are plain arrays pointing at VTK memory. They are valid
  **only while the owner lives**:

```julia
da = VTK.data_array(Float64, 1)
VTK.resize!(da, 4)
v = VTK.raw_data(da.obj)
da = nothing; GC.gc()
v[1]   # INVALID: the array may be gone
```

Keep the owner referenced for the view's lifetime.

## ⚠️ Do not attach owner-capturing finalizers to views

A natural "fix" for the borrowing rule is `finalizer(arr -> owner, view)`,
keeping the VTK object alive as long as the view lives. **It corrupts
concurrent pipelines.** Measured on this codebase: ~25% of test runs failed
with heisenbug garbage reads once C++ objects started dying on Julia's GC
finalizer threads, while the main thread was inside VTK algorithms; the
failures vanished under `--gcthreads=1`.

The rule that emerged: **C++ VTK objects must die on the main thread.**
Views must not extend C++ lifetimes into GC finalizers. The proper long-term
fix is "wrapper-owns-everything" (return the owning `VTKDataArray` wrapper
from every accessor, so dropping it — always user code, main thread —
releases the object). Until then: keep owners alive; it is cheap and total.

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

- Hold the grid/array while reading views of it.
- Treat views obtained before `resize!` as dead.
- Don't reduce over freshly-grown storage before writing it.
- Don't build your own finalizer bridges to VTK objects.
