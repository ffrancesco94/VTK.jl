# Build the C++ wrapper module against VTK_jll.
# Usage: julia --project=. gen/build_wrapper.jl
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
