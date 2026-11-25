# Diagnostics and operation failures

High-level readers, filters, temporal updates, and writers use scoped VTK
diagnostics. Each operation has a fresh collector attached to its target
algorithm; no messages are stored in a process-global buffer.

## Severity and status

- VTK errors and unsuccessful native return statuses throw `VTKError`.
- Warnings do not make a successful operation fail. They are reported as
  warnings and remain available in the diagnostic-returning API.
- Normal text and debug messages are nonfatal diagnostic records.
- A null required output is an error. A valid dataset with zero points or
  cells is a successful empty result.

`VTKError` and `VTKDiagnostic` retain the operation, algorithm class, optional
filename, native status, message, and severity. This makes reader and writer
failures identifiable without parsing a combined output-window string.

## Scope, nesting, and concurrency

A collector lives only for the duration of its native operation. Observers are
removed on success and exceptional exits, so messages cannot leak into the
next call. Nested operations have nested diagnostic scopes. Independent
algorithms can execute concurrently without a global diagnostics lock;
collectors synchronize their own callbacks.

As with VTK itself, concurrently updating or mutating the **same** algorithm
is unsupported. Pipeline outputs may keep their VTK object alive, but retaining
an algorithm and updating it again can still mutate earlier output contents.

The generated raw API remains raw: calls such as `Update` do not implicitly
become Julia checked operations. Use the high-level facade when typed errors,
warning separation, and contextual diagnostics are required.
