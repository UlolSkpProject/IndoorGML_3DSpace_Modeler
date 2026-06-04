# Refactor Session Context

Last updated: 2026-06-04

## Current Repository State

- Branch: `main`
- Latest pushed commit: `ee80a92 Refactor step 6 guard attribute writes`
- Working tree was clean when this context document was written.
- Refactor progress is tracked in `docs/RefactorTODO.md`.
- Manual baseline/regression checklist is in `docs/refactor_checklist.md`.

## Completed Refactor Steps

### 0. Baseline behavior checklist

- Added `docs/refactor_checklist.md`.
- No Ruby behavior change was made for this step.
- Step 0 was intentionally not committed alone; it was included with the first pushed refactor commit.

### 1. Remove modal UI from observer flow

Commit: `bfff49f Refactor step 1 defer observer UI messages`

- `SceneGroupGuard` no longer calls `UI.messagebox` directly.
- `SceneGroupGuard` receives a notifier callback.
- `IndoorModel#defer_ui_message` uses `UI.start_timer(0, false)` before showing the message box.
- Existing user-facing message text was preserved.

### 2. Clarify observer reentry guards

Commit: `47d18b9 Refactor step 2 clarify observer guards`

- Added guard helpers that restore previous guard values instead of always forcing `false`.
- `space_features_changed` and `cell_space_changed` now return whether work was actually handled.
- Observer logs are emitted only when the callback was actually handled, reducing misleading repeated logs.
- Test observation: SketchUp-level `onElementModified` may still appear multiple times; IndoorGML observer logs should not repeat for one handled change.

### 3. Unify observer attach key logic

Commit: `56c74c1 Refactor step 3 unify observer attach keys`

- Initial `persistent_id` based observer attach key direction was tested and rejected.
- Reason: after CellSpace create -> Undo -> Redo, observer reattach could be skipped because the same `persistent_id` looked already observed.
- Final direction: observer attach registry uses `object_id`, because it tracks whether the current Ruby wrapper has an observer attached.
- Added helper methods while preserving existing attach timing and observer types.
- Important distinction:
  - `object_id`: current Ruby wrapper identity, appropriate for observer attach state.
  - `persistent_id`: SketchUp entity identity, appropriate for feature lookup/registry.
  - `entityID`: current SketchUp session ID, useful for removed callback matching.

### 4. Clarify FeatureRegistry key names

Commit: `fddaf6e Refactor step 4 clarify registry keys`

- Renamed ambiguous internal registry hashes:
  - `@cell_spaces_by_entity` -> `@cell_spaces_by_entity_object`
  - `@cell_spaces_by_entity_id` -> `@cell_spaces_by_persistent_id`
  - `@cell_spaces_by_sketchup_entity_id` -> `@cell_spaces_by_entity_id_for_removed_callback`
- Renamed removed-callback lookup method:
  - `cell_space_by_sketchup_entity_id` -> `find_cell_space_by_removed_entity_id`
- Behavior was intended to stay unchanged.

### 5. Add valid feature accessors

Commit: `37f2257 Refactor step 5 add valid feature accessors`

- Added:
  - `CellSpace#valid_sketchup_group`
  - `State#valid_component_instance`
  - `Transition#valid_edge`
- Kept existing accessors.
- Updated higher-risk call sites in overlay, attribute serializer, and temp exporter to use safe accessors.

### 6. Guard AttributeSerializer writes

Commit: `ee80a92 Refactor step 6 guard attribute writes`

- Verified the TODO reason before implementation: it was valid.
- Attribute write methods now check entity validity before writing.
- Write methods return `true` on success and `false` on invalid entity or write failure.
- Attribute key/value structure was not changed.
- `copy_indoor_attributes` now guards both source and target.
- Failures log a minimal Ruby Console line:
  - `[IndoorGML] Attribute write failed: ...`

## Important Testing Notes

- `IndoorGML_PrimalSpaceFeatures` is locked in normal operation.
- Do not include primal group move/scale/rotate tests unless specifically testing a lock bug.
- EditMode enter/exit can emit `CellSpaceObserver#onChangeEntity` because lock state changes are entity changes in SketchUp.
- If a CellSpace move emits one `CellSpaceObserver#onChangeEntity` log, observer attach is probably not duplicated.
- `onElementModified` logs may be SketchUp or non-IndoorGML observer-level logs and are not by themselves proof of duplicate IndoorGML observer attachment.

## Known Existing Bugs Deferred

These were observed during refactor testing and recorded in `docs/RefactorTODO.md` under the final critical bug section.

### EditMode CellSpace copy/paste duplicates identity

- In EditMode, copying and pasting a CellSpace can duplicate IndoorGML attributes.
- The copy can appear to share id/duality/runtime meaning with the original.
- This can corrupt runtime registry, State/Transition relations, and Export GML ids.

### EditMode Ctrl+Z active_path / lock mismatch

- Reproduced in the 0-step baseline commit `8203f20`, so this is not caused by steps 1-6.
- Scenario:
  1. Enter EditMode.
  2. Press `Ctrl+Z`.
  3. EditMode UI/state can remain active while SketchUp editing context falls back to root entities.
  4. `primal_group` can remain unlocked.
  5. User can move/rotate `primal_group`, damaging internal CellSpace geometry/topology.
- Relevant existing flow:
  - `ModelObserver#onActivePathChanged`
  - `IndoorModel#active_path_changed`
  - `EditorSession#active_path_changed`
  - `EditorSession#enforce_edit_context`
- SketchUp may not expose exact Undo contents. Debug by comparing before/after snapshots of:
  - `Sketchup.active_model.active_path`
  - `EditorSession` editing state
  - `@editing_active_path_target`
  - `primal_group.locked?`
  - active-path and transaction observer callback logs

### Primal group move corrupts child CellSpace transforms

- Root cause analysis was added on 2026-06-05 after inspecting `SceneGroupGuard` usage.
- `SceneGroupGuard#synchronize_from` is only reached through this path:
  - `SpaceFeaturesObserver#onChangeEntity`
  - `IndoorModel#space_features_changed`
  - `IndoorModel#enforce_space_features_constraints`
  - `@scene_group_guard.enforce(ordered_space_features_groups)`
  - `SceneGroupGuard#synchronize_from`
- Current `ordered_space_features_groups` returns:
  - `@primal_group`
  - every valid `CellSpace` SketchUp group
- This mixes a parent group (`IndoorGML_PrimalSpaceFeatures`) with child CellSpace groups in the same transform synchronization set.
- `primal_group.transformation` is root-space, while each CellSpace group `transformation` is local to `primal_group.entities`.
- When `primal_group` is moved, child CellSpaces already move in world space through the parent transform. `synchronize_from` then also writes the parent transform into each child group local transform, effectively applying the movement a second time and corrupting CellSpace positions/topology.
- This logic likely came from, or only made sense for, an older sibling-root setup such as `PrimalSpaceFeatures` plus deprecated `DualSpaceFeatures`, where two root-level groups could reasonably share a transform.
- It is not valid for the current structure where `DualSpaceFeatures` is deprecated and CellSpaces live under `PrimalSpaceFeatures`.
- Recommended fix direction:
  - Remove transform synchronization between `primal_group` and CellSpace child groups.
  - Treat `primal_group` transform changes as invalid and restore/reject them.
  - Keep CellSpace transform handling per-cell through normal CellSpace lifecycle logic.
  - Do not use one shared `synchronize_from(group, groups)` policy across parent and child groups.

## Recommended Next Step

Do not jump directly into step 7 if the goal is stable future testing.

Recommended order:

1. Add a new urgent bug-fix step before step 7, or move the final critical bug section forward.
2. Fix EditMode `Ctrl+Z` active_path/lock mismatch first.
3. Then fix or explicitly guard CellSpace copy/paste duplicate identity.
4. Resume refactor step 7 after EditMode invariants are stable.

Reason: steps 7 onward touch transformation, root-child detection, SceneGroupGuard, Undo/Redo refresh, and dirty queue behavior. The known EditMode bugs can make those tests ambiguous.

## Process Rules To Continue

- Perform only one step at a time.
- Only work on the earliest incomplete step unless the user explicitly changes the TODO order.
- Do not modify the real SketchUp test completion checkbox; only the user checks it.
- Codex only checks the stage-level Codex completion checkbox, not the detailed task checkboxes.
- Before starting each future step, verify that the TODO's stated reason for the change is actually valid against the current code and observed behavior.
- After a user says the real SketchUp test for a step is complete, commit and push before moving to the next step.
