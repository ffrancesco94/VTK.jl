using Documenter, DocumenterVitepress

using VTK

makedocs(;
    modules = [VTK],
    authors = "Francesco",
    repo = "https://github.com/ffrancesco94/VTK.jl",
    sitename = "VTK.jl",
    format = DocumenterVitepress.MarkdownVitepress(;
        # No scheme: DocumenterVitepress prepends "https://" itself when
        # building the "Edit this page" links.
        repo = "github.com/ffrancesco94/VTK.jl",
        devbranch = "main",
        devurl = "dev",
        # WITH scheme: DocumenterVitepress strips the domain to derive the
        # VitePress `base` path; without it the base becomes
        # "/ffrancesco94.github.io/VTK.jl" and the deployed site loads no CSS.
        deploy_url = "https://ffrancesco94.github.io/VTK.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => "getting_started.md",
        "Tutorials" => [
            "Building a mesh" => "tutorials/mesh.md",
            "Data arrays & fields" => "tutorials/arrays.md",
            "Reading & writing files" => "tutorials/io.md",
            "Filter pipelines" => "tutorials/filters.md",
        ],
        "Implementation notes" => [
            "Architecture & layering" => "implementation/architecture.md",
            "Memory & ownership" => "implementation/ownership.md",
            "Zero-copy array views" => "implementation/zerocopy.md",
            "The WrapIt driver" => "implementation/wrapit.md",
        ],
        "API reference" => "reference.md",
    ],
    warnonly = true,
    doctest = false,  # VTK needs the compiled wrapper; examples are illustrative
)

# Deployment (gh-pages) is opt-in so local builds never push:
#   DOCS_DEPLOY=true julia --project=docs docs/make.jl
if get(ENV, "DOCS_DEPLOY", "false") == "true"
    DocumenterVitepress.deploydocs(;
        repo = "github.com/ffrancesco94/VTK.jl",
        devbranch = "main",
        push_preview = true,
    )
else
    println("""
    Site rendered into docs/build/1/ (VitePress runs automatically during
    makedocs when node/npm are available). Serve locally with:
        cd docs && npm run docs:dev
    or open docs/build/1/index.html directly.
    """)
end
