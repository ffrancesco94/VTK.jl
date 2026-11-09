# Publish the generated wrapper sources to the VTK_cxxwrap repo.
#
# Run after `gen/build_wrapper.jl` (the PublishWrapper tag workflow does both):
#
#   VTKJL_WRAPPER_VERSION=0.2.0 julia --project=. gen/publish_wrapper.jl
#
# Environment:
#   VTKJL_WRAPPER_VERSION  wrapper version, with or without leading "v" (required)
#   VTKJL_CXXWRAP_URL      repo URL (default github.com/ffrancesco94/VTK_cxxwrap)
#   VTKJL_CXXWRAP_DIR      reuse a local clone instead of cloning into a tempdir
#   VTK_CXXWRAP_TOKEN      PAT used for pushing (CI); locally, plain git
#                          credentials are used when this is unset
#
# The script copies exactly the MANIFEST below into the clone, commits, tags
# v<version> and pushes. It errors if a generated source file in build/cxx or
# build/jl is not listed in the MANIFEST (anti-drift), if a manifest source is
# missing (run the build first), or if the tag already exists on the remote
# (no force-pushing published wrappers).

const ROOT = dirname(@__DIR__)
const DRIVER = joinpath(ROOT, "gen", "wrapit")
const BUILD = joinpath(DRIVER, "build")

# src (relative to gen/wrapit) => destination (relative to the VTK_cxxwrap root)
const MANIFEST = [
    "build/cxx/jlVTKGen.cxx"  => "src/cpp/jlVTKGen.cxx",
    "build/cxx/jlVTKGen.h"    => "src/cpp/jlVTKGen.h",
    "build/cxx/JlClasses.cxx" => "src/cpp/JlClasses.cxx",
    "build/cxx/Wrapper.h"     => "src/cpp/Wrapper.h",
    "build/cxx/dbg_msg.h"     => "src/cpp/dbg_msg.h",
    "build/cxx/shim_auto.cpp" => "src/cpp/shim_auto.cpp",
    "shim_vtkjl.h"            => "src/cpp/shim_vtkjl.h",
    "shim_vtkjl.cpp"          => "src/cpp/shim_vtkjl.cpp",
    "build/jl/VTKGen.jl"      => "src/jl/VTKGen.jl",
]

const CXXWRAP_URL_DEFAULT = "https://github.com/ffrancesco94/VTK_cxxwrap.git"

function parse_version()
    raw = get(ENV, "VTKJL_WRAPPER_VERSION", "")
    version = replace(raw, r"^v" => "")
    occursin(r"^\d+\.\d+\.\d+$", version) ||
        error("set VTKJL_WRAPPER_VERSION to a version like 0.2.0 (got \"$raw\")")
    return version
end

# Release builds must pin WrapIt to a full commit SHA (the PublishWrapper
# workflow exports the contents of gen/wrapit/wrapit.pin as VTKJL_WRAPIT_REF)
# so that a given VTK.jl tag always generates the same sources. Local builds
# may leave it unset (upstream main) or set a branch/tag.
function check_wrapit_pin!()
    ref = get(ENV, "VTKJL_WRAPIT_REF", "")
    isempty(ref) && return
    occursin(r"^[0-9a-f]{40}$", ref) ||
        error("VTKJL_WRAPIT_REF is \"$ref\" — release builds must pin WrapIt to a " *
              "full commit SHA (see gen/wrapit/wrapit.pin)")
end

function wrapit_sha()
    src = joinpath(BUILD, "wrapit-src")
    isdir(joinpath(src, ".git")) || return "unknown"
    return readchomp(`git -C $src rev-parse HEAD`)
end

function check_build_products!()
    for dir in (joinpath(BUILD, "cxx"), joinpath(BUILD, "jl"))
        isdir(dir) || error("missing $dir — run `julia --project=. gen/build_wrapper.jl` first")
        for f in readdir(dir)
            endswith(f, r"\.(cxx|cpp|h|jl)$") || continue
            rel = relpath(joinpath(dir, f), DRIVER)
            any(p -> p.first == rel, MANIFEST) ||
                error("generated file gen/wrapit/$rel is not in the MANIFEST of " *
                      "gen/publish_wrapper.jl — add it to the manifest deliberately")
        end
    end
    for (src, _) in MANIFEST
        isfile(joinpath(DRIVER, src)) ||
            error("missing gen/wrapit/$src — run `julia --project=. gen/build_wrapper.jl` first")
    end
end

function open_checkout(url)
    local_dir = get(ENV, "VTKJL_CXXWRAP_DIR", "")
    work = if !isempty(local_dir)
        isdir(joinpath(local_dir, ".git")) ||
            error("VTKJL_CXXWRAP_DIR=$local_dir is not a git clone of VTK_cxxwrap")
        run(`git -C $local_dir fetch origin`)
        local_dir
    else
        d = mktempdir(prefix = "vtk_cxxwrap-")
        run(`git clone $url $d`)
        d
    end
    # Work on a detached HEAD at the remote default branch so a reused local
    # clone keeps its branches untouched.
    head = try
        replace(readchomp(`git -C $work symbolic-ref --short refs/remotes/origin/HEAD`),
                "origin/" => "")
    catch
        "main"
    end
    run(`git -C $work checkout -q --detach origin/$head`)
    isempty(readchomp(`git -C $work status --porcelain`)) ||
        error("$work has uncommitted changes; commit or stash them first")
    return work, head
end

function ensure_identity!(work)
    success(`git -C $work config --get user.email`) ||
        run(`git -C $work config user.email "vtk.jl@localhost"`)
    success(`git -C $work config --get user.name`) ||
        run(`git -C $work config user.name "VTK.jl release"`)
end

function push_url(url)
    token = get(ENV, "VTK_CXXWRAP_TOKEN", "")
    isempty(token) && return url
    replace(url, r"^https://" => "https://x-access-token:$token@")
end

function main()
    version = parse_version()
    tag = "v" * version
    check_wrapit_pin!()
    check_build_products!()

    url = get(ENV, "VTKJL_CXXWRAP_URL", CXXWRAP_URL_DEFAULT)
    pushurl = push_url(url)
    work, default_branch = open_checkout(url)

    isempty(readchomp(`git -C $work ls-remote --tags $pushurl refs/tags/$tag`)) ||
        error("tag $tag already exists on $url — published wrappers are immutable; " *
              "bump the version instead")
    success(`git -C $work rev-parse -q --verify refs/tags/$tag`) &&
        error("tag $tag already exists locally in $work")

    for (src, dst) in MANIFEST
        d = joinpath(work, dst)
        mkpath(dirname(d))
        cp(joinpath(DRIVER, src), d; force = true)
    end
    add_args = String["git", "-C", work, "add", "--"]
    append!(add_args, map(last, MANIFEST))
    run(Cmd(add_args))
    ensure_identity!(work)

    vtk_sha = readchomp(`git -C $ROOT rev-parse HEAD`)
    wpit = wrapit_sha()
    msg = "Publish wrapper $tag from VTK.jl @ $vtk_sha (wrapit @ $wpit)"
    if success(`git -C $work diff --cached --quiet`)
        println("Wrapper sources unchanged; tagging existing VTK_cxxwrap HEAD.")
    else
        run(`git -C $work commit -q -m $msg`)
    end
    run(`git -C $work tag -a $tag -m $msg`)
    run(`git -C $work push $pushurl HEAD:refs/heads/$default_branch`)
    run(`git -C $work push $pushurl refs/tags/$tag`)

    sha = readchomp(`git -C $work rev-parse HEAD`)
    println("""
    Published $tag to $url @ $sha

    Next: in Yggdrasil, set the GitSource of V/VTK_julia/build_tarballs.jl to
    this commit ($sha) with version = v"$version", and open the PR. The VTK.jl
    tag already declares [compat] VTK_julia_jll = "$version"; once the JLL
    registers, the tag becomes installable.""")
end

main()
