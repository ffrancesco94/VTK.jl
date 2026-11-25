# Native sanitizer checks

The ordinary CI suite includes concurrent pipelines and GC pressure. For native
memory diagnostics, the local wrapper build also accepts `VTKJL_SANITIZE`,
which is forwarded to the compiler and linker. For example, on a GCC/Linux
development machine:

```sh
VTKJL_SANITIZE=address,undefined julia --project=. gen/build_wrapper.jl
rm -rf ~/.julia/compiled/v1.*/VTK
ASAN_OPTIONS=detect_leaks=0 \
LD_PRELOAD="$(gcc -print-file-name=libasan.so)" \
VTKJL_LIB="$PWD/wrapper/build/libvtk_julia.so" \
JULIA_NUM_THREADS=4 \
julia --project=test --gcthreads=2 test/runtests.jl
```

`LD_PRELOAD` is needed because Julia loads the instrumented wrapper as a shared
library. Leak detection is disabled in this example because JIT and artifact
allocations are outside the wrapper's ownership contract; address and undefined
behavior checks remain enabled. Rebuild without `VTKJL_SANITIZE` and clear the
VTK precompile cache before returning to a normal development library.

Sanitizer results supplement, rather than replace, the deterministic functional
and concurrent/GC tests. Findings in VTK_jll itself should be distinguished from
memory errors in `libvtk_julia` before changing ownership code.
