# wrapit_src.jl — build the wrapit executable from source (our fork with the
# macro-truncation fix) instead of using WrapIt_jll.
#
#   repo: ENV["VTKJL_WRAPIT_REPO"] (default ffrancesco94/wrapit)
#   ref:  ENV["VTKJL_WRAPIT_REF"]  (default "main"; branch or tag)
#   VTKJL_WRAPIT_UPDATE=1          fetch + reset + rebuild on next run
#   VTKJL_CLANG_PREFIX             passed to CMake as CLANG_PREFIX if set
#
# Products (gitignored): build/wrapit-src, build/wrapit-build/wrapit.
# Requirements: git, CMake, a C++17 compiler, libclang dev headers +
# resource dir, OpenSSL dev headers.

const WRAPIT_REPO = get(ENV, "VTKJL_WRAPIT_REPO", "https://github.com/ffrancesco94/wrapit")
const WRAPIT_REF = get(ENV, "VTKJL_WRAPIT_REF", "main")

wrapit_exe() = joinpath(BUILD_DIR, "wrapit-build", "wrapit")

function ensure_wrapit!()
    src = joinpath(BUILD_DIR, "wrapit-src")
    if !isdir(src)
        mkpath(BUILD_DIR)
        run(`git clone --depth 1 -b $WRAPIT_REF $WRAPIT_REPO $src`)
    elseif get(ENV, "VTKJL_WRAPIT_UPDATE", "") == "1"
        run(`git -C $src fetch --depth 1 origin $WRAPIT_REF`)
        run(`git -C $src reset --hard FETCH_HEAD`)
        rm(wrapit_exe(); force = true)
    end
    if !isfile(wrapit_exe())
        bld = joinpath(BUILD_DIR, "wrapit-build")
        args = String["-DCLANG_JLL=ON", "-DCMAKE_BUILD_TYPE=Release"]
        haskey(ENV, "VTKJL_CLANG_PREFIX") &&
            push!(args, "-DCLANG_PREFIX=$(ENV["VTKJL_CLANG_PREFIX"])")
        run(`cmake -S $src -B $bld $args`)
        run(`cmake --build $bld -j $(Sys.CPU_THREADS)`)
    end
    return wrapit_exe()
end
