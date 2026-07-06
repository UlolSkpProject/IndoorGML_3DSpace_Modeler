# Architecture Decisions

## Transition Creation Policy

The extension currently targets IndoorGML 1.0.3 transition behavior: any two valid CellSpaces with a detected shared boundary can produce an adjacency Transition. A dedicated ConnectionSpace is not required for two General CellSpaces.

If IndoorGML 1.1 behavior is added later, the policy should be introduced as an explicit compatibility mode instead of leaving alternative rules commented in `AdjacencyService`.

## Domain Namespace Policy

Feature model classes use the `IndoorCore` namespace consistently. `AbstractFeature` provides the common feature identity shape for `CellSpace`, `State`, and `Transition`.

This is not a pure domain boundary. The current `indoor3d/domain` folder should be understood as SketchUp-backed runtime model code until a future refactor separates pure IndoorGML model objects from SketchUp entity adapters.

## SketchUp State Ownership Policy

SketchUp API usage is allowed in application and infrastructure code when the API is part of normal extension behavior. The architecture goal is not to hide all SketchUp types, but to keep each mutable SketchUp state owned by one clear controller or use case.

Recommended ownership:

| SketchUp state or operation | Preferred owner |
| --- | --- |
| `active_path` changes | `ActivePathController` once extracted |
| complex model operations | `TransactionRunner` or the responsible use case |
| topology timers | topology scheduler/service |
| edit-mode locks | edit lock controller |
| edit-mode visibility snapshots | visibility controller |
| overlay registration and invalidation | overlay controller |
| observer callback branching | observer router/handler |

The practical rule is that the same SketchUp state should not be directly changed by many unrelated classes. Existing code can migrate gradually by adding service/controller wrappers first, then replacing direct calls.

## Extraction Policy

Do not create a new class only to make the code look layered. Extract a responsibility when at least two of these are true:

- It owns independent state.
- It changes for a different reason than the current class.
- It has a start, finish, cleanup, or restore lifecycle.
- The same policy is repeated in several places.
- It is worth testing without the current large object.
- A different implementation is plausible.
- The current class does not need to know the internal steps.

Examples with high extraction value are active path handling, validation process execution, validation report rendering, edit visibility, edit locks, and export snapshots. Examples with low value are one-line formatting helpers or trivial material-name indirections.

## Val3dity Platform Policy

The bundled Val3dity runtime is Windows-only. `Val3dityRunner` points at `val3dity-windows-x64-v2.2.0` and intentionally rejects non-Windows hosts before trying to execute the validator.

If macOS or another platform is supported later, add a platform-specific vendor runtime and select the vendor root by host OS instead of falling back to the Windows executable.
