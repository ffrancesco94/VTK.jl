using VTK
using Test

@testset "dictionary-like point and cell data" begin
    coordinates = Float64[
        0 1 0 0;
        0 0 1 0;
        0 0 0 1
    ]
    cells = [
        VTK.MeshCell(VTK.VTKCellTypes.VTK_TETRA, [1, 2, 3, 4])
    ]
    grid = VTK.UnstructuredGrid(coordinates, cells)

    # Association-oriented assignment copies ordinary Julia arrays.
    temperature = Float32[1, 2, 3, 4]
    point_data(grid)["temperature"] = temperature

    stored_temperature = point_data(grid)["temperature"]
    @test stored_temperature isa VTK.VTKDataArray{Float32}
    @test size(stored_temperature) == (1, 4)
    @test Array(stored_temperature) == reshape(temperature, 1, :)

    # Confirm that ordinary assignment copied the input.
    temperature[1] = 99
    @test stored_temperature[1, 1] == 1

    # Both lookup forms refer to the same mutable VTK storage.
    stored_temperature[1, 1] = 5
    @test grid["temperature", :point][1, 1] == 5

    grid["temperature", :point][1, 2] = 6
    @test point_data(grid)["temperature"][1, 2] == 6

    # Grid-oriented assignment also copies ordinary arrays.
    pressure = Float64[10, 20, 30, 40]
    grid["pressure", :point] = pressure
    pressure[1] = -1

    @test point_data(grid)["pressure"][1, 1] == 10
    @test point_data(grid)["pressure"] isa VTK.VTKDataArray{Float64}

    # Cell-data assignment validates against ncells(grid).
    cell_data(grid)["density"] = [1.25]
    @test size(cell_data(grid)["density"]) == (1, 1)
    @test grid["density", :cell][1, 1] == 1.25

    grid["cell_id", :cell] = Int32[7]
    @test cell_data(grid)["cell_id"] isa VTK.VTKDataArray{Int32}
    @test cell_data(grid)["cell_id"][1, 1] == 7

    # Both assignment forms replace an existing name through the same path.
    point_data(grid)["dual"] = [1.0, 2.0, 3.0, 4.0]
    grid["dual", :point] = [5.0, 6.0, 7.0, 8.0]
    @test vec(VTK.data(point_data(grid)["dual"])) ==
          [5.0, 6.0, 7.0, 8.0]

    # Attaching an existing VTK array does not add another data copy.
    attached = VTK.data_array(Float64)
    VTK.resize!(attached, 4)
    attached[1, :] .= [1.0, 2.0, 3.0, 4.0]

    point_data(grid)["attached"] = attached
    @test VTK.name(attached) == "attached"

    attached[1, 1] = 42
    @test point_data(grid)["attached"][1, 1] == 42

    point_data(grid)["attached"][1, 2] = 43
    @test attached[1, 2] == 43

    # Existing VTK arrays can also be attached through grid indexing.
    attached_grid = VTK.data_array(Int32)
    VTK.resize!(attached_grid, 4)
    attached_grid[1, :] .= Int32[4, 3, 2, 1]

    grid["attached_grid", :point] = attached_grid
    attached_grid[1, 4] = 99
    @test point_data(grid)["attached_grid"][1, 4] == 99

    # Existing add_array! compatibility, including raw smart pointers.
    compatible = VTK.data_array(Float64)
    VTK.name!(compatible, "compatible")
    VTK.resize!(compatible, 4)
    compatible[1, :] .= [4.0, 5.0, 6.0, 7.0]

    returned = VTK.add_array!(point_data(grid), compatible.obj)
    @test returned isa VTK.VTKDataArray{Float64}
    @test point_data(grid)["compatible"][1, 3] == 6.0

    compatible[1, 3] = 60
    @test point_data(grid)["compatible"][1, 3] == 60

    # Existing field-array conveniences continue to work.
    @test VTK.field_array(point_data(grid), "temperature")[1, 1] == 5
    @test VTK.field_array(point_data(grid), "missing") === nothing
    @test VTK.name(VTK.field_array_raw(
        point_data(grid), "temperature")) == "temperature"
    @test Set(VTK.field_array_names(point_data(grid))) ==
          Set(keys(point_data(grid)))

    # Dictionary behavior.
    @test haskey(point_data(grid), "temperature")
    @test !haskey(point_data(grid), "missing")
    @test get(point_data(grid), "missing", nothing) === nothing
    @test_throws KeyError point_data(grid)["missing"]
    @test_throws KeyError grid["missing", :point]

    @test length(point_data(grid)) == length(keys(point_data(grid)))
    @test length(collect(point_data(grid))) == length(point_data(grid))

    for (name, array) in point_data(grid)
        @test name isa String
        @test array isa VTK.VTKDataArray
        # The final expression intentionally avoids identity assumptions about
        # separately constructed VTKDataArray wrappers. Check values instead.
        @test ntuples(array) == 4
    end

    # Tuple-count failures happen before the array is attached.
    @test_throws DimensionMismatch (
        point_data(grid)["too_short"] = [1.0, 2.0]
    )
    @test !haskey(point_data(grid), "too_short")

    @test_throws DimensionMismatch (
        grid["too_long", :point] = [1.0, 2.0, 3.0, 4.0, 5.0]
    )
    @test !haskey(point_data(grid), "too_long")

    @test_throws DimensionMismatch (
        cell_data(grid)["bad_cell_data"] = [1.0, 2.0]
    )
    @test !haskey(cell_data(grid), "bad_cell_data")

    @test_throws ArgumentError (
        grid["invalid", :face] = [1.0, 2.0, 3.0, 4.0]
    )
    @test_throws ArgumentError VTK.set_array!(
        grid, "invalid", [1.0, 2.0, 3.0, 4.0]; association=:face)

    # add_array! requires a name because it cannot infer one from a key.
    unnamed = VTK.data_array(Float64)
    VTK.resize!(unnamed, 4)
    @test_throws ArgumentError VTK.add_array!(point_data(grid), unnamed)

    # Deletion is idempotent.
    delete!(point_data(grid), "pressure")
    @test !haskey(point_data(grid), "pressure")
    delete!(point_data(grid), "pressure")
    @test !haskey(point_data(grid), "pressure")
end
