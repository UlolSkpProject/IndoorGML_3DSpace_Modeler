# Undo/Redo Runtime Refresh Note

CellSpace delete/redo is not expected to refresh every CellSpace directly.

Current targeted delete flow:

- `CellSpaceObserver#onEraseEntity`
- `IndoorModel#cell_space_erased`
- `erase_cell_space(cell_space, erase_sketchup_group: false)`
- `erase_transitions_for_state`

This path scans transitions to find connections to the removed State, but it does not call `refresh_runtime_data`.

The expensive path can happen when Undo restores a CellSpace entity:

- `PrimalEntitiesObserver#onElementAdded`
- `IndoorModel#primal_entity_added`
- `stale_cell_space_runtime?`
- fallback to `refresh_runtime_data`

`refresh_runtime_data` resets and restores runtime collections, recenters runtime CellSpaces, and rebuilds runtime transitions. On large models this can feel like a long redo/undo stall.

Future optimization target:

- Avoid full `refresh_runtime_data` in restored CellSpace cases when the entity attributes are sufficient to rebuild only the affected CellSpace, State, and adjacent transitions.
- Add timing logs around `primal_entity_added`, `cell_space_erased`, `refresh_runtime_data`, and `erase_transitions_for_state` before changing behavior.
