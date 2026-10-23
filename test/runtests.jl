using VTK
using Test

@testset "VTK.jl" begin
    include("dataarray.jl")
    include("filters.jl")
    include("oracle.jl")
end
