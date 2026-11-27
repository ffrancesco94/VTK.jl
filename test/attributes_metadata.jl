using VTK
using Test

function metadata_tests_hex_grid()
    coordinates = Float64[
        0 1 1 0 0 1 1 0;
        0 0 1 1 0 0 1 1;
        0 0 0 0 1 1 1 1
    ]
    cells = [
        VTK.MeshCell(
            VTK.VTKCellTypes.VTK_HEXAHEDRON,
            1:8,
        ),
    ]
    return VTK.UnstructuredGrid(coordinates, cells)
end

function metadata_tests_image()
    image = VTK.ImageData_new()
    VTK.SetDimensions(image, 2, 3, 4)
    VTK.SetOrigin(image, 1.0, -2.0, 0.5)
    VTK.SetSpacing(image, 0.5, 0.25, 2.0)

    # Deliberately nonsymmetric, to detect row/column-order mistakes.
    VTK.SetDirectionMatrix(
        image,
        1.0, 2.0, 3.0,
        0.0, 4.0, 5.0,
        0.0, 0.0, 6.0,
    )
    return image
end

@testset "general field-data associations" begin
    grid = metadata_tests_hex_grid()

    @test npoints(grid) == 8
    @test ncells(grid) == 1

    # These tuple counts deliberately match neither points nor cells.
    field_data(grid)["time"] = [2.5]
    grid["history", :field] = [0.0, 0.5, 1.0, 1.5]
    grid["matrix_metadata", :field] = reshape(1.0:10.0, 2, 5)

    @test haskey(field_data(grid), "time")
    @test haskey(field_data(grid), "history")
    @test haskey(field_data(grid), "matrix_metadata")

    @test field_data(grid)["time"][1, 1] == 2.5
    @test grid["time", :field][1, 1] == 2.5
    @test vec(VTK.data(field_data(grid)["history"])) ==
        [0.0, 0.5, 1.0, 1.5]
    @test size(field_data(grid)["matrix_metadata"]) == (2, 5)

    # Both assignment paths have copying behavior.
    history = [1.0, 2.0, 3.0]
    field_data(grid)["copied_history"] = history
    history[1] = 99.0
    @test field_data(grid)["copied_history"][1, 1] == 1.0

    # Existing VTK arrays are attached without another data copy.
    attached = VTK.data_array(Float64)
    VTK.resize!(attached, 2)
    attached[1, :] .= [4.0, 5.0]

    field_data(grid)["attached"] = attached
    attached[1, 1] = 40.0
    @test field_data(grid)["attached"][1, 1] == 40.0

    field_data(grid)["attached"][1, 2] = 50.0
    @test attached[1, 2] == 50.0

    # Point, cell, and general field associations are independent.
    point_data(grid)["shared_name"] = fill(1.0, 8)
    cell_data(grid)["shared_name"] = fill(2.0, 1)
    field_data(grid)["shared_name"] = [3.0, 4.0, 5.0]

    @test point_data(grid)["shared_name"][1, 1] == 1.0
    @test cell_data(grid)["shared_name"][1, 1] == 2.0
    @test field_data(grid)["shared_name"][1, 1] == 3.0

    # General field support must not weaken point/cell validation.
    @test_throws DimensionMismatch (
        point_data(grid)["bad_points"] = [1.0, 2.0]
    )
    @test_throws DimensionMismatch (
        cell_data(grid)["bad_cells"] = [1.0, 2.0]
    )
    @test !haskey(point_data(grid), "bad_points")
    @test !haskey(cell_data(grid), "bad_cells")

    returned = VTK.set_array!(
        grid,
        "set_array_field",
        [7.0, 8.0];
        association = :field,
    )
    @test returned isa VTK.VTKDataArray
    @test field_data(grid)["set_array_field"][1, 2] == 8.0

    @test_throws ArgumentError (
        grid["invalid", :faces] = [1.0]
    )

    delete!(field_data(grid), "history")
    @test !haskey(field_data(grid), "history")

    # Deletion is idempotent.
    delete!(field_data(grid), "history")
    @test !haskey(field_data(grid), "history")

    # Nonnumeric arrays remain discoverable but are not numeric values.
    VTK.AddStringArrayForTesting(
        VTK.GetFieldDataOwned(grid),
        "label",
    )
    @test haskey(field_data(grid), "label")
    @test "label" in keys(field_data(grid))
    @test_throws VTK.VTKUnsupportedTypeError field_data(grid)["label"]
end

@testset "active point and cell attributes" begin
    grid = metadata_tests_hex_grid()

    values = Dict{Symbol, Any}(
        :scalars => collect(1.0:8.0),
        :vectors => reshape(collect(1.0:24.0), 3, 8),
        :normals => reshape(collect(25.0:48.0), 3, 8),
        :tcoords => reshape(collect(1.0:16.0), 2, 8),
        :tensors => reshape(collect(1.0:72.0), 9, 8),
    )

    for (attribute, array_values) in values
        array_name = String(attribute)
        point_data(grid)[array_name] = array_values

        returned = VTK.activate!(
            grid,
            array_name;
            association = :point,
            attribute = attribute,
        )
        @test returned === grid

        active = VTK.active_array(
            grid;
            association = :point,
            attribute = attribute,
        )

        @test active isa VTK.VTKDataArray
        @test VTK.name(active) == array_name
        @test Array(active) == array_values
    end

    # Activating one kind of attribute must not deactivate the others.
    for attribute in keys(values)
        @test VTK.name(
            VTK.active_array(
                grid;
                association = :point,
                attribute = attribute,
            )
        ) == String(attribute)
    end

    # Existing active-scalar conveniences delegate to the same mechanism.
    point_data(grid)["pressure"] = collect(11.0:18.0)
    VTK.activate_point_data!(grid, "pressure")

    @test VTK.name(
        VTK.active_array(
            grid;
            association = :point,
            attribute = :scalars,
        )
    ) == "pressure"

    @test VTK.name(
        VTK.active_array(
            grid;
            association = :point,
            attribute = :vectors,
        )
    ) == "vectors"

    # Point and cell active attributes are independent.
    cell_data(grid)["cell_temperature"] = [3.0]
    VTK.activate_cell_data!(grid, "cell_temperature")

    @test VTK.name(
        VTK.active_array(
            grid;
            association = :cell,
            attribute = :scalars,
        )
    ) == "cell_temperature"

    @test VTK.name(
        VTK.active_array(
            grid;
            association = :point,
            attribute = :scalars,
        )
    ) == "pressure"

    # General field data has no active dataset attributes.
    field_data(grid)["time"] = [0.0]

    @test_throws ArgumentError VTK.activate!(
        grid,
        "time";
        association = :field,
        attribute = :scalars,
    )
    @test_throws ArgumentError VTK.active_array(
        grid;
        association = :field,
        attribute = :scalars,
    )

    @test_throws KeyError VTK.activate!(
        grid,
        "missing";
        association = :point,
        attribute = :scalars,
    )
    @test_throws ArgumentError VTK.activate!(
        grid,
        "pressure";
        association = :point,
        attribute = :unknown,
    )
    @test_throws ArgumentError VTK.active_array(
        grid;
        association = :point,
        attribute = :unknown,
    )

    # A grid without active arrays returns nothing.
    empty_grid = metadata_tests_hex_grid()
    @test VTK.active_array(
        empty_grid;
        association = :point,
        attribute = :scalars,
    ) === nothing
end

@testset "active-array ownership" begin
    function make_detached_active_array()
        grid = metadata_tests_hex_grid()
        point_data(grid)["temperature"] = collect(1.0:8.0)
        VTK.activate!(grid, "temperature"; attribute = :scalars)
        return VTK.active_array(grid; attribute = :scalars)
    end

    active = make_detached_active_array()
    GC.gc(true)

    @test VTK.name(active) == "temperature"
    @test vec(VTK.data(active)) == collect(1.0:8.0)

    active[1, 1] = 20.0
    @test active[1, 1] == 20.0
end

@testset "dataset metadata" begin
    grid = metadata_tests_hex_grid()

    @test VTK.bounds(grid) == (
        0.0, 1.0,
        0.0, 1.0,
        0.0, 1.0,
    )
    @test VTK.center(grid) == (0.5, 0.5, 0.5)

    image = metadata_tests_image()

    @test VTK.dimensions(image) == (2, 3, 4)
    @test VTK.extent(image) == (0, 1, 0, 2, 0, 3)
    @test VTK.origin(image) == (1.0, -2.0, 0.5)
    @test VTK.spacing(image) == (0.5, 0.25, 2.0)

    expected_direction = [
        1.0 2.0 3.0;
        0.0 4.0 5.0;
        0.0 0.0 6.0
    ]
    @test VTK.direction(image) == expected_direction

    # Metadata is copied into ordinary Julia values.
    image_bounds = VTK.bounds(image)
    @test image_bounds isa NTuple{6, Float64}
    @test VTK.origin(image) isa NTuple{3, Float64}
    @test VTK.dimensions(image) isa NTuple{3, Int}
end

@testset "array ranges" begin
    scalar = VTK.data_array([3.0, -2.0, 7.0, 1.0])
    @test VTK.array_range(scalar) == (-2.0, 7.0)
    @test VTK.array_range(scalar; component = 0) == (-2.0, 7.0)

    vectors = VTK.data_array(
        [
            1.0 4.0;
            -2.0 8.0;
            3.0 0.0
        ]
    )
    @test VTK.array_range(vectors; component = 0) == (1.0, 4.0)
    @test VTK.array_range(vectors; component = 1) == (-2.0, 8.0)
    @test VTK.array_range(vectors; component = 2) == (0.0, 3.0)

    nonfinite = VTK.data_array([1.0, NaN, Inf, -Inf, 3.0])
    @test VTK.array_range(nonfinite; finite = true) == (1.0, 3.0)

    @test_throws BoundsError VTK.array_range(scalar; component = -2)
    @test_throws BoundsError VTK.array_range(scalar; component = 1)
    @test_throws BoundsError VTK.array_range(vectors; component = 3)
end

@testset "dataset show methods" begin
    grid = metadata_tests_hex_grid()

    point_data(grid)["temperature"] = collect(1.0:8.0)
    cell_data(grid)["material"] = [4.0]
    field_data(grid)["time"] = [0.0]
    VTK.activate_point_data!(grid, "temperature")
    VTK.activate_cell_data!(grid, "material")

    compact = sprint(show, grid)
    @test compact == "vtkUnstructuredGrid(points=8, cells=1)"

    detailed = sprint(show, MIME("text/plain"), grid)

    @test occursin("vtkUnstructuredGrid", detailed)
    @test occursin("points: 8", detailed)
    @test occursin("cells:  1", detailed)
    @test occursin("bounds:", detailed)

    @test occursin("point arrays:", detailed)
    @test occursin("temperature", detailed)
    @test occursin("cell arrays:", detailed)
    @test occursin("material", detailed)
    @test occursin("field arrays:", detailed)
    @test occursin("time", detailed)

    @test occursin("active point scalars: temperature", detailed)
    @test occursin("active cell scalars: material", detailed)

    # Nonnumeric arrays are listed by name without numeric indexing.
    VTK.AddStringArrayForTesting(
        VTK.GetFieldDataOwned(grid),
        "label",
    )
    detailed_with_label = sprint(show, MIME("text/plain"), grid)
    @test occursin("label", detailed_with_label)
end
