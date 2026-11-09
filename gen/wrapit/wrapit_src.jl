# wrapit_src.jl — build the wrapit executable from upstream source instead of
# using WrapIt_jll. Upstream includes the macro-truncation and libclang-22 fixes.
#
#   repo: ENV["VTKJL_WRAPIT_REPO"] (default grasph/wrapit)
#   ref:  ENV["VTKJL_WRAPIT_REF"]  (default "main"; branch, tag, or full
#         commit SHA — release builds pin a SHA via gen/wrapit/wrapit.pin)
#   VTKJL_WRAPIT_UPDATE=1          fetch + reset + rebuild on next run
#   VTKJL_CLANG_PREFIX             passed to CMake as CLANG_PREFIX if set
#
# Products (gitignored): build/wrapit-src, build/wrapit-source,
# build/wrapit-build/wrapit.
# Requirements: git, CMake, a C++17 compiler, libclang dev headers +
# resource dir, OpenSSL dev headers.

const WRAPIT_REPO = get(ENV, "VTKJL_WRAPIT_REPO", "https://github.com/grasph/wrapit")
const WRAPIT_REF = get(ENV, "VTKJL_WRAPIT_REF", "main")

wrapit_exe() = joinpath(BUILD_DIR, "wrapit-build", "wrapit")

# `git clone -b` only accepts branches/tags, not commit SHAs, so for a pinned
# SHA we init + fetch the commit directly (GitHub allows fetching reachable
# SHAs) and check out FETCH_HEAD.
function clone_wrapit!(src)
    if occursin(r"^[0-9a-f]{40}$", WRAPIT_REF)
        run(`git init -q $src`)
        run(`git -C $src remote add origin $WRAPIT_REPO`)
        run(`git -C $src fetch --depth 1 origin $WRAPIT_REF`)
        run(`git -C $src checkout -q FETCH_HEAD`)
    else
        run(`git clone --depth 1 -b $WRAPIT_REF $WRAPIT_REPO $src`)
    end
end

function ensure_wrapit!()
    src = joinpath(BUILD_DIR, "wrapit-src")
    stamp = joinpath(BUILD_DIR, "wrapit-source")
    source = "repo = $WRAPIT_REPO\nref = $WRAPIT_REF\n"
    # Besides explicit updates, rebuild when the configured source changes.
    # The stamp also migrates checkouts created before upstream became default.
    update = get(ENV, "VTKJL_WRAPIT_UPDATE", "") == "1" ||
             !isfile(stamp) || read(stamp, String) != source
    if !isdir(src)
        mkpath(BUILD_DIR)
        clone_wrapit!(src)
    elseif update
        run(`git -C $src remote set-url origin $WRAPIT_REPO`)
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
    write(stamp, source)
    return wrapit_exe()
end
