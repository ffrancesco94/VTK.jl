# Memory & ownership

VTK is reference-counted; Julia is garbage-collected. The bridge between
them is the subtlest part of VTK.jl. **Object lifetime and data lifetime are
separate questions:** an owning handle can keep a VTK object alive while that
object's contents continue to alias, and change with, a parent or pipeline.

## Lifetime rules by API kind

- **Factories own.** `UnstructuredGrid()`, `Points()`, `read_vtu(...)`, and
  similar constructors return a CxxWrap `vtkSmartPointer{T}` holding a strong
  VTK reference. Julia's finalizer queues the wrapper for deferred destruction;
  a safe drain releases that reference, and VTK destroys the object when its
  reference count reaches zero.
- **`take_ref` getters own a VTK reference; they are not merely borrowed.**
  `point_data(grid)`, `points(grid)`, `field_array_raw(...)`, and other
  getters implemented with `take_ref` call `Register` before returning a smart
  pointer. The resulting Julia handle therefore keeps the referenced object
  alive independently of the parent handle. It still denotes the *same*
  object as the parent uses, so mutations are shared while both refer to it.
- **Raw `CxxPtr` values are truly borrowed.** Low-level conversions such as
  `_cp(...)` do not call `Register` and do not extend lifetime. Keep the
  owning smart pointer (and, where relevant, its parent/container) alive for
  every raw-pointer call. Do not store a raw pointer beyond the owner's
  lifetime.
- **Pipeline outputs own the output object's lifetime, not a snapshot of its
  contents.** `GetOutput` uses `take_ref`, so the returned data object can
  outlive the algorithm handle. However, a reader or filter can reuse and
  mutate that same object on a later `Update`. Retaining the handle prevents
  use-after-free; it does not prevent the next update from changing its data.
- **Shallow copies share storage.** A VTK `ShallowCopy` creates another data
  object but shares underlying arrays with the source. Mutating shared array
  contents remains visible through both objects.
- **Deep copies are detached.** `DeepCopy`/`DeepCopyDataObject` duplicate the
  data arrays as well as the containing object, so later source or pipeline
  updates do not alter the copy. `Array(a::VTKDataArray)` likewise copies the
  current values into independent Julia storage.

GC-stress tests with thousands of allocations and surviving objects exercise
the smart-pointer ownership path.

## Temporal results

`read_timestep`, `read_at`, and `eachstep` default to `copy=true`, returning a
deep copy that remains unchanged by later reader updates. Passing
`copy=false` explicitly selects the pipeline-output rule above: the handle
owns a reference to the output object, but its contents are borrowed from the
mutable pipeline and must be consumed or copied before the next update.

The one-shot `read_ensight(path)` and `read_cgns(path)` helpers intentionally
avoid that extra copy. Their temporary reader is never advanced again, and
the returned output handle owns the reference needed to keep the object
alive.

`timesteps(reader)` returns a copy of the time vector. Mutating it neither
changes reader metadata nor affects subsequent timestep selection.

## Views own through the wrapper

`data(x)` returns a `VTKDataArray` that *holds* the smart pointer as a field;
`raw_data(x)` returns a flat view derived from that wrapper. The derivation
chain — `ReshapedArray → VTKDataArray → SmartPointer` — keeps the C++ object
alive **structurally**, with no finalizers on views:

```julia
da = VTK.data_array(Float64, 1)
VTK.resize!(da, 4)
v = VTK.raw_data(da.obj)
da = nothing; GC.gc()   # the original handle is gone…
v[1]                    # …and the view still owns a share of the object
```

This is the "wrapper-owns-everything" design. After the *last* wrapper/view
chain is collected, its finalizer adds the native wrapper to the deferred
deletion queue; the VTK reference is released at the next safe drain. Keeping
an object alive does **not** keep an old data buffer valid after reallocation;
see below.

## Cached-view synchronization and resize semantics

A `VTKDataArray` caches its zero-copy `Matrix`, the array's VTK modification
time (`GetMTime`), its dimensions, and its data-buffer address. Before array
operations it compares that signature with the current array. VTK operations
such as `SetNumberOfTuples` do not necessarily advance `GetMTime`, so the
shape and address checks are essential. If another wrapper, `a.obj`, or a raw
VTK call has structurally changed the array, the wrapper rebuilds its view
before proceeding. `refresh!(a)` forces the same rebuild explicitly. This
makes independently wrapped aliases coherent without making scalar indexing
type-unstable.

`resize!` calls VTK's `SetNumberOfTuples`, validates that the new tuple count
is nonnegative, and refreshes immediately. There are two important limits:

1. **Old independently obtained views still dangle after reallocation.**
   Synchronization updates a `VTKDataArray`; it cannot retrofit a previously
   extracted matrix, raw buffer, or derived view whose pointer or dimensions
   belong to the old allocation. Discard and recreate such views after any
   operation that might reallocate. Never test or "repair" a dangling buffer
   by reading it.
2. **Growth is uninitialized.** VTK may expose allocator leftovers in newly
   grown tuples. Initialize the grown region before reading it or performing
   whole-array reductions.

These signature checks are not a thread-safety mechanism; concurrent
structural mutation and Julia array access remain unsafe.

## Multiblock containers

`GetBlockByIndex`, and therefore `block(mb, i)`, uses `take_ref`. The returned
block owns a VTK reference and **can outlive the parent multiblock handle or
container**. It is not a detached copy: while the block remains in `mb`,
parent and child handles refer to the same object, so mutation through either
is visible through the other. Replacing or removing the block changes the
container's reference, not the already returned handle's object.

`set_block!(mb, i, child)` uses VTK's `SetBlock`, which retains `child` in the
container. The caller does **not** need to keep its original child handle
alive afterward. Retention again means shared ownership, not copying:
mutating the child through any surviving handle mutates the block stored in
the parent.

## GC finalizer threads and deferred destruction

VTK smart-pointer wrappers require special treatment. CxxWrap's default
finalizer deletes the C++ smart pointer immediately; that can call
`UnRegister` and `vtkGarbageCollector::Collect` on a GC finalizer thread while
another thread executes a filter. This caused reproducible heap corruption in
the threaded test suite.

The wrapper now specializes CxxWrap's `Finalizer<vtkSmartPointer<T>>` to
**enqueue** the native wrapper without entering VTK. Queue insertion uses a
dedicated mutex, so finalizers on multiple GC threads are safe.

`drain_vtk_deletions()` performs the actual C++ deletions. With one Julia
thread, high-level operations and common factories drain automatically at call
boundaries; no other Julia thread can be inside VTK at those points. With
multiple Julia threads, automatic draining is disabled because factories and
raw calls can be active independently of scoped operations. At a verified
quiescent point, after all VTK tasks/native worker threads have finished, call:

```julia
VTK.drain_vtk_deletions(force = true)
```

Without `force=true`, the multithreaded call throws rather than risking
concurrent destruction. Raw-only workloads use the same explicit function for
reclamation. Queued wrappers use memory until a drain, so applications running
large multithreaded batches should establish regular quiescent points. Process
exit may reclaim any remaining queue without entering VTK again.

Views themselves still have no owner-capturing finalizers; structural ownership
and deferred native destruction are complementary. Do not attach custom
finalizers that mutate or delete VTK objects.

## Practical checklist

- Keep owning wrappers alive around every raw `CxxPtr` call.
- Treat getters and multiblock children as owning aliases, not borrowed raw
  pointers and not detached copies.
- Treat retained pipeline outputs as mutable until explicitly deep-copied.
- Discard all previously derived buffers/views after possible reallocation.
- Initialize freshly grown storage before reading or reducing it.
- Establish quiescent `drain_vtk_deletions(force=true)` points after
  multithreaded/raw batches.
- Do not attach custom finalizers that mutate or delete VTK objects or views.
