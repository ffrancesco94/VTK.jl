using Test
using VTK

@testset "scoped diagnostics" begin
    @testset "severities and warning policy" begin
        source = VTK.LineSource_new()
        result = VTK._vtk_operation_result(
            (1, [1, 2, 3], ["visible warning", "text only", "debug only"]),
            :Update,
            source,
            "case.vtk",
        )
        @test [d.severity for d in result.diagnostics] == [:warning, :text, :debug]
        @test all(d -> d.operation === :Update, result.diagnostics)
        @test all(d -> d.algorithm == "vtkLineSource", result.diagnostics)
        @test all(d -> d.filename == "case.vtk", result.diagnostics)
        @test_logs (:warn, "visible warning") VTK._check_vtk_result(result)

        # An error event is fatal even if a native operation returned success.
        error_result = VTK._vtk_operation_result(
            (1, [0], ["synthetic error"]), :Update, source, nothing
        )
        @test_throws VTK.VTKError VTK._check_vtk_result(error_result)

        # A failed native status is fatal without requiring an error message.
        failed_result = VTK._vtk_operation_result(
            (0, Int[], String[]), :Update, source, nothing
        )
        @test_throws VTK.VTKError VTK._check_vtk_result(failed_result)

        for (severity, symbol) in (("warning", :warning), ("text", :text),
                                   ("debug", :debug), ("error", :error))
            native = VTK.EmitScopedDiagnosticForTesting(
                source, severity, "native scoped $severity")
            scoped = VTK._vtk_operation_result(native, :Update, source, nothing)
            @test only(scoped.diagnostics).severity === symbol
            @test only(scoped.diagnostics).message == "native scoped $severity"
            if severity == "error"
                @test_throws VTK.VTKError VTK._check_vtk_result(scoped)
            elseif severity == "warning"
                @test_logs (:warn, "native scoped warning") VTK._check_vtk_result(scoped)
            else
                @test_logs VTK._check_vtk_result(scoped)
            end
        end
    end

    @testset "typed context and stale isolation" begin
        mktempdir() do dir
            path = joinpath(dir, "missing.vtu")
            reader = VTK.XMLUnstructuredGridReader_new()
            VTK.SetFileName(reader, path)
            result = VTK.update_with_diagnostics(reader; filename = path)
            @test result.status == 0
            @test any(d -> d.severity === :error, result.diagnostics)
            @test all(d -> d.operation === :Update, result.diagnostics)
            @test all(d -> d.algorithm == "vtkXMLUnstructuredGridReader", result.diagnostics)
            @test all(d -> d.filename == path, result.diagnostics)

            checked_reader = VTK.XMLUnstructuredGridReader_new()
            VTK.SetFileName(checked_reader, path)
            err = try
                VTK.update!(checked_reader; filename = path)
                nothing
            catch exception
                exception
            end
            @test err isa VTK.VTKError
            if err isa VTK.VTKError
                @test err.operation === :Update
                @test err.algorithm == "vtkXMLUnstructuredGridReader"
                @test err.filename == path
                @test err.status == 0
                @test !isempty(err.diagnostics)
                message = sprint(showerror, err)
                @test occursin("vtkXMLUnstructuredGridReader", message)
                @test occursin(path, message)
            end

            # A later valid operation on the same algorithm must not inherit
            # messages from the failed attempts above.
            valid = joinpath(dir, "valid.vtu")
            VTK.write_vtu(VTK.UnstructuredGrid(), valid)
            VTK.SetFileName(reader, valid)
            VTK.update!(reader; filename = valid)
            @test VTK.npoints(VTK.checked_output(reader; filename = valid)) == 0

            # Events emitted outside a scoped operation, including on the same
            # algorithm, must not leak into its next diagnostic result.
            source = VTK.LineSource_new()
            for severity in ("error", "warning", "text", "debug")
                VTK.EmitDiagnostic(source, severity, "outside scoped capture")
                VTK.EmitDiagnostic(source, Symbol(severity), "symbol severity")
            end
            # Raw calls remain raw and do not reintroduce a Julia-side buffer.
            @test VTK.Update(source) === nothing
            clean = VTK.update_with_diagnostics(source)
            @test clean.status == 1
            @test isempty(clean.diagnostics)
        end
    end

    @testset "high-level reader and writer failures" begin
        mktempdir() do dir
            missing = joinpath(dir, "not-there.vtu")
            read_error = try
                VTK.read_vtu(missing)
                nothing
            catch exception
                exception
            end
            @test read_error isa VTK.VTKError
            if read_error isa VTK.VTKError
                @test read_error.filename == missing
                @test read_error.operation === :Update
            end

            destination = joinpath(dir, "missing-parent", "out.vtu")
            write_error = try
                VTK.write_vtu(VTK.UnstructuredGrid(), destination)
                nothing
            catch exception
                exception
            end
            @test write_error isa VTK.VTKError
            if write_error isa VTK.VTKError
                @test write_error.filename == destination
                @test write_error.operation === :Write
                @test write_error.status == 0
            end
        end
    end

    @testset "checked owning output" begin
        source = VTK.LineSource_new()
        VTK.update!(source)
        output = VTK.checked_output(source; operation = "Update")
        @test VTK.GetClassName(output) == "vtkPolyData"

        # Empty outputs are valid; checked_output must not inspect cardinality.
        empty_grid = VTK.UnstructuredGrid_new()
        filter = VTK.CellDataToPointData_new()
        VTK.SetInputData(filter, empty_grid)
        VTK.update!(filter)
        empty_output = VTK.checked_output(filter)
        @test VTK.npoints(empty_output) == 0
        @test VTK.ncells(empty_output) == 0

        writer = VTK.XMLUnstructuredGridWriter_new()
        err = try
            VTK.checked_output(writer; operation = "Write", filename = "out.vtu")
            nothing
        catch exception
            exception
        end
        @test err isa VTK.VTKError
        if err isa VTK.VTKError
            @test err.operation === :Write
            @test err.algorithm == "vtkXMLUnstructuredGridWriter"
            @test err.filename == "out.vtu"
            @test err.status == 0
            @test length(err.diagnostics) == 1
            @test only(err.diagnostics).severity === :error
            @test occursin("owning output", only(err.diagnostics).message)
        end
    end

    @testset "independent algorithms are isolated" begin
        mktempdir() do dir
            results = Vector{Any}(undef, 8)
            paths = [joinpath(dir, "missing-$i.vtp") for i in eachindex(results)]
            Threads.@threads for i in eachindex(results)
                if isodd(i)
                    reader = VTK.XMLPolyDataReader_new()
                    VTK.SetFileName(reader, paths[i])
                    results[i] = VTK.update_with_diagnostics(reader; filename = paths[i])
                else
                    source = VTK.LineSource_new()
                    VTK.EmitDiagnostic(source, :warning, "outside scoped capture")
                    results[i] = VTK.update_with_diagnostics(source; filename = paths[i])
                end
            end
            for i in eachindex(results)
                result = results[i]
                @test all(d -> d.filename == paths[i], result.diagnostics)
                if isodd(i)
                    @test result.status == 0
                    @test any(d -> d.severity === :error, result.diagnostics)
                else
                    @test result.status == 1
                    @test isempty(result.diagnostics)
                end
            end
        end
    end

    @testset "downcast exception context" begin
        @test occursin("expected vtkPolyData", sprint(
            showerror, VTK.VTKTypeError("vtkPolyData", "vtkImageData")
        ))
        @test occursin("vtkOtherData", sprint(
            showerror, VTK.VTKUnsupportedTypeError("vtkOtherData")
        ))
    end
end
