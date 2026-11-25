# Native smart-pointer destruction and GC finalizer threads.
#
# CxxWrap's finalizer for every vtkSmartPointer is specialized in
# shim_vtkjl.h. It queues the C++ wrapper without calling UnRegister. VTK
# destruction is therefore never performed directly by a GC finalizer thread.

"""
    drain_vtk_deletions(; force=false) -> Int

Destroy queued VTK smart-pointer wrappers at a quiescent point and return the
number drained. With one Julia thread this is safe at ordinary call boundaries
and is also done automatically at high-level operation/factory entry points.

With multiple Julia threads, another task or raw binding call may be inside
VTK even when no high-level operation is running. Consequently the default
call throws. Use `force=true` only after all tasks and native threads using VTK
have finished and no other VTK call can start until draining returns. Raw-only
workloads use this function for reclamation in both threading modes.
"""
function drain_vtk_deletions(; force = false)
    if Threads.nthreads() > 1 && !force
        throw(ArgumentError(
            "draining VTK deletions with multiple Julia threads requires " *
            "force=true at a verified quiescent point"))
    end
    return Int(DrainVTKDeletions())
end

"""Number of native wrappers currently waiting for a safe deletion point."""
pending_vtk_deletions() = Int(PendingVTKDeletionCount())

function _drain_vtk_deletions_if_serial()
    Threads.nthreads() == 1 && DrainVTKDeletions()
    return nothing
end
