using VTK
using Test

@testset "VTK.jl" begin
    include("dataarray.jl")
    include("smartptr.jl")
    include("typedarray.jl")
    include("cells.jl")
    include("filters.jl")
    include("oracle.jl")
    include("io_structured.jl")
    include("io_multiblock.jl")
    include("io_cfd.jl")
    include("io_legacy.jl")
end
