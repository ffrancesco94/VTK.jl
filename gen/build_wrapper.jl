# Build the C++ binding module against VTK_jll.
# Usage: julia --project=. gen/build_wrapper.jl
#
# This drives the WrapIt-based generator in gen/wrapit (generate CxxWrap
# bindings from the VTK 9.7 headers, merge the hand shim, compile) and
# installs the merged library at wrapper/build/libvtk_julia.so — the default
# location loaded by src/VTK.jl.
#
# Fallback: the legacy hand-written CMake wrapper remains available via
# `julia --project=. gen/build_wrapper_cmake.jl`; ENV["VTKJL_LIB"] overrides
# which library VTK.jl loads (see README).
const ROOT = dirname(@__DIR__)
const DRIVER = joinpath(ROOT, "gen", "wrapit")

# The driver has its own environment (WrapIt_jll et al.).
run(`$(Base.julia_cmd()) --project=$DRIVER -e 'using Pkg; Pkg.instantiate()'`)
run(`$(Base.julia_cmd()) --project=$DRIVER $(joinpath(DRIVER, "build.jl"))`)

const TARGET_DIR = joinpath(ROOT, "wrapper", "build")
mkpath(TARGET_DIR)
cp(joinpath(DRIVER, "build", "shipped", "libvtk_julia.so"),
   joinpath(TARGET_DIR, "libvtk_julia.so"); force = true)
println("Installed: ", joinpath(TARGET_DIR, "libvtk_julia.so"))
