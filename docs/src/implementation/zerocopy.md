# Zero-copy array views

`VTKDataArray`'s headline feature — plain Julia arrays over VTK memory —
rests on three deliberate mechanisms.

## 1. Dispatching to the concrete storage type

`vtkDataArray` is abstract; its data lives in subclasses
(`vtkDoubleArray`, …). Calling `GetVoidPointer()` through the virtual API
would be type-erased, but the *address* of the buffer is type-independent.
The C++ side (`wrapper/src/vtk_julia.cpp`) uses `vtkArrayDispatch` to get
the statically-typed array, extracts `ValueType*`, and hands that pointer to
Julia:

```cpp
struct ZeroCopyMatrixWorker {
  template <typename ArrayT>
  void operator()(ArrayT* arr, jl_value_t*& out) {
    using V = std::remove_const_t<typename ArrayT::ValueType>;
    V* ptr = static_cast<V*>(arr->GetVoidPointer(0));
    out = reinterpret_cast<jl_value_t*>(
        jlcxx::make_julia_array(ptr, ncomp, nt).wrapped());
  }
};
```

## 2. Creating the Array at target dimensionality

VTK's storage is component-fastest — exactly Julia's column-major for an
`(ncomp, ntuples)` matrix. The wrapper creates the Julia array **directly**
as 2-D (or 1-D for `raw_data`) via CxxWrap's variadic
`make_julia_array(ptr, dims...)`.

Why not reshape on the Julia side? `reshape`/`reinterpret` produce
*immutable wrapper arrays* (`ReshapedArray`/`ReinterpretArray`) which
(a) cannot carry finalizers and (b) propagate through every API boundary
awkwardly. Real `Array{T,N}` objects keep the whole surface simple and
type-stable.

One CxxWrap subtlety: Julia wrapper types are pre-registered only for
1-D arrays, so the worker calls
`create_if_not_exists<jlcxx::ArrayRef<V,2>>()` first — otherwise
`julia_type<ArrayRef<V,2>>()` throws "has no Julia wrapper" at runtime.

## 3. The AOS caveat

Zero-copy is offered **only for AOS (array-of-structs) arrays**, mirroring
VTK's own buffer-protocol caveat: SOA/variant arrays are rejected with a
clear error ("array is not AOS"). This is the right trade-off — VTK's
writers/readers and most filters produce AOS anyway.

## The typed wrapper's cached view

`VTKDataArray{T}` constructs once, then:

- **discovers** `T` from the array's VTK scalar-type id
  (`GetDataType` → `VTK_TO_JULIA_TYPE`) — so `VTKDataArray(obj)` is always
  honest about the element type, and `VTKDataArray{WrongType}(obj)` throws;
- caches the zero-copy `Matrix{T}` and implements `getindex`/`setindex!`
  against it — type-stable, `@inferred`-able;
- refreshes the cache in `resize!`.

Element access thus costs a bounds check + a load — no virtual calls, no
conversion.

## When to use what

| need | use |
|---|---|
| typed, ergonomic access | `VTK.field_array`, `VTK.points_array`, `VTK.coordinates` → `VTKDataArray{T}` |
| untyped bulk view | `VTK.data`/`VTK.raw_data` on a smart pointer |
| copy out | `Matrix(vtk_arr)` / `vec(...)` |
