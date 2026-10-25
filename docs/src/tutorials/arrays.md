# Tutorial: data arrays & fields

VTK revolves around `vtkDataArray`s. VTK.jl makes them feel like ordinary
Julia matrices — with zero-copy views and type-stable indexing.

## The typed wrapper

```julia
using VTK

da = VTK.data_array(Float64, 3)    # 3-component Float64 array
VTK.resize!(da, 100)               # 100 tuples
size(da)                           # (3, 100): (ncomponents, ntuples)
eltype(da)                         # Float64

da[:, 1] = [1.0, 2.0, 3.0]
da[2, 1]                           # 2.0 — plain, type-stable getindex
```

`VTKDataArray{T} <: AbstractMatrix{T}` — indexing, broadcasting, `sum`,
`vec`, iteration all work as expected, and **writes go straight through to
VTK's storage** (zero copy in both directions).

Rows are components, columns are tuples: `da[j, i]` is component `j` of
tuple `i`, matching VTK's component-fastest AOS layout.

## Fields on a dataset

Field data hangs off the dataset in three buckets — point data, cell data,
and the underlying field-data container:

```julia
grid = <the hex mesh from the mesh tutorial>

pd = VTK.point_data(grid)          # vtkPointData smart pointer
VTK.field_array_names(pd)          # ["temperature"]

vtk_arr = VTK.field_array(pd, "temperature")   # VTKDataArray{Float64}
vtk_arr[1, 3] = 99.0               # writes through

VTK.field_array(pd, "missing")     # nothing (no exception)
```

`field_array` looks the array up, checks membership, and wraps it in the
typed wrapper; use `field_array_raw` if you want the untyped smart pointer
instead.

`activate_point_data!(grid, "temperature")` marks an array as the active
scalar — filters like `contour` operate on it (see the
[filters tutorial](filters.md)).

## Factory types and discovery

Arrays obtained from VTK (e.g. `VTK.field_array`, `VTK.points_array`) are
*discovered*: the wrapper reads the storage type from the array itself, so
`eltype` always matches reality — and mismatches are rejected:

```julia
arr = VTK.field_array(VTK.point_data(grid), "temperature")
VTK.VTKDataArray{Float32}(arr.obj)   # ArgumentError: stores Float64, not Float32
```

The scalar-type maps cover every VTK numeric type (`VTK_CHAR`…`VTK_UNSIGNED_LONG_LONG`);
see the `VTK_TO_JULIA_TYPE` / `JULIA_TO_VTK_TYPE` tables in
[`src/typedarray.jl`](https://github.com/ffrancesco94/VTK.jl/blob/main/src/typedarray.jl).

## Resizing and invalidation

`resize!` changes the number of tuples; the typed wrapper refreshes its
cached view automatically:

```julia
VTK.resize!(da, 200)
size(da)                           # (3, 200)
```

Two caveats worth internalizing:

1. **Old views dangle.** VTK may reallocate on growth; views obtained
   *before* a `resize!` must not be used afterwards.
2. **Growth is not zeroed.** Newly exposed elements contain whatever the
   allocator left there — initialize them explicitly if you sum/reduce over
   the whole array.

Both behaviors come from VTK itself; see
[Memory & ownership](../implementation/ownership.md) for the underlying
model.

## Low-level access

`raw_data`/`data` are ownership-safe convenience views over any array smart
pointer: `data` returns the owning `VTKDataArray` wrapper, `raw_data` a
flat `vec` of it. Both keep the underlying storage alive for as long as
they're referenced — the original handle may be dropped:

```julia
flat = VTK.raw_data(arr.obj)       # flat component-fastest view (owns)
mat  = VTK.data(arr.obj)           # owning VTKDataArray (ncomp, ntuples)
```

Next: [reading & writing files](io.md).
