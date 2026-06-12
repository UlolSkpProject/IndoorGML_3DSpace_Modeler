# Architecture Decisions

## Transition Creation Policy

The extension currently targets IndoorGML 1.0 transition behavior: any two valid CellSpaces with a detected shared boundary can produce an adjacency Transition. A dedicated ConnectionSpace is not required for two General CellSpaces.

If IndoorGML 1.1 behavior is added later, the policy should be introduced as an explicit compatibility mode instead of leaving alternative rules commented in `AdjacencyService`.

## Domain Namespace Policy

`GML::AbstractFeature` intentionally lives under the `GML` namespace because it represents the common feature identity shape used by exported IndoorGML features. Runtime feature classes such as `IndoorCore::CellSpace`, `IndoorCore::State`, and `IndoorCore::Transition` inherit from it while remaining part of the SketchUp-backed runtime model.

This is not a pure domain boundary. The current `indoor3d/domain` folder should be understood as SketchUp-backed runtime model code until a future refactor separates pure IndoorGML model objects from SketchUp entity adapters.

## Val3dity Platform Policy

The bundled Val3dity runtime is Windows-only. `Val3dityRunner` points at `val3dity-windows-x64-v2.2.0` and intentionally rejects non-Windows hosts before trying to execute the validator.

If macOS or another platform is supported later, add a platform-specific vendor runtime and select the vendor root by host OS instead of falling back to the Windows executable.
