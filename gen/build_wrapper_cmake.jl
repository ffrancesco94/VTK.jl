# Build the C++ wrapper module against VTK_jll using the legacy hand-written
# CMake wrapper (wrapper/src/vtk_julia.cpp).
#
# This is the fallback build path; the default is the WrapIt-driven
# gen/build_wrapper.jl. The product lands at the same location
# (wrapper/build/libvtk_julia.so), so VTK.jl picks it up automatically unless
# ENV["VTKJL_LIB"] says otherwise.
using VTK_jll
using CxxWrap

wrapper_src = joinpath(@__DIR__, "..", "wrapper")
build_dir = joinpath(wrapper_src, "build")
mkpath(build_dir)

prefix = CxxWrap.prefix_path()
println("JlCxx prefix: ", prefix)
println("VTK artifact: ", VTK_jll.artifact_dir)

run(`cmake -S $(wrapper_src) -B $(build_dir)
     -DCMAKE_BUILD_TYPE=Release
     -DVTK_JLL_DIR=$(VTK_jll.artifact_dir)
     -DCMAKE_PREFIX_PATH=$(prefix)`)
run(`cmake --build $(build_dir) -j $(Sys.CPU_THREADS)`)
println("Built: ", joinpath(build_dir, "libvtk_julia.so"))
