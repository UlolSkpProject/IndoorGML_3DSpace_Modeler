# Observer Guard Matrix

This document records the current observer guard behavior. It is descriptive
only; it does not define a new policy.

## Common Suppression

`observer_routing_suppressed?` is shared by the high-level observer routes in
`IndoorModel::ObserverRouting` and `IndoorModel::FeatureLifecycle`.

It suppresses routing when any of these conditions is active:

| Guard | Owner | Purpose | Restoration |
|---|---|---|---|
| `@syncing` | `RuntimeSupport#sync`, `with_runtime_observer_suppression` | Suppress callbacks caused by extension-owned runtime and attribute writes. | `with_guard_flag` ensure block |
| `@bulk_cell_space_conversion` | `FeatureLifecycle#with_bulk_cell_space_conversion` | Suppress per-entity add/remove routing while bulk conversion commits successful jobs, reports failed jobs, and uses runtime snapshot restore only for transaction-level failures or zero-success cleanup. | `with_guard_flag` ensure block |
| `@transaction_reconciliation` | `RuntimeSupport#reconcile_runtime_after_transaction` | Suppress observer replay while undo/redo reconciliation rebuilds runtime from current model state. | `with_guard_flag` ensure block |
| `transaction_replay_pending?` | `Indoor3DGmlModelObserver#handle_transaction_replayed` | Suppress callbacks between SketchUp undo/redo notification and the deferred reconciliation timer. | `finish_transaction_replay` / `clear_transaction_replay!` |

Current test coverage:

| Test | Covered behavior |
|---|---|
| `test/test_observer_routing_guards.rb` | `@syncing`, bulk conversion, transaction reconciliation, and replay-pending suppression for selected routes. |
| `test/test_guard_ownership.rb` | Guard restoration for nested refresh, relocation, finish editing, and exception paths. |
| `test/test_runtime_reconciliation.rb` | Transaction reconciliation rebuilds runtime without persistence writes. |

## Callback Matrix

Legend:

- `Yes`: the callback currently checks this guard or common suppression path.
- `No`: no direct check exists in the current route.
- `n/a`: not relevant to this callback's current responsibility.

| Callback | Common suppression | relocating | erasing | finishing | constraining | Reason |
|---|---:|---:|---:|---:|---:|---|
| `root_entity_added` | Yes | Yes | No | No | No | Root add routing restores or relocates IndoorGML entities. Common suppression avoids extension-owned writes and transaction replay; `@relocating_entity` prevents relocation from re-entering itself. No current code shows erasing, finish editing, or constraint enforcement as owners of root add handling. |
| `primal_entity_added` | Yes | Yes | No | No | No | Primal add routing handles CellSpace copy independence, stale runtime refresh, and non-CellSpace relocation. Common suppression avoids extension-owned writes and transaction replay; `@relocating_entity` prevents copy/move operations from recursively adding the same entity. No direct erasing or finish guard exists. |
| `primal_entity_removed` | Yes | Yes | Yes | No | No | Primal remove routing erases runtime CellSpaces for deleted entities. Common suppression avoids replay/bulk/sync mutations; `@erasing` prevents `erase_cell_space` from re-entering removal; `@relocating_entity` prevents move/copy cleanup from being treated as user deletion. |
| `space_features_changed` | Yes | No | Yes | Yes | Yes | SpaceFeatures changes enforce naming and reject scale. Common suppression avoids extension-owned writes and replay; `@constraining_space_features` prevents constraint enforcement from re-triggering itself; `@erasing` ignores changes while groups are being removed; `@finishing_editing` suppresses noise during edit-mode shutdown. No relocating check is present. |
| `cell_space_changed` | Yes | No | Yes | No | No | CellSpace change routing classifies attribute/name/transform changes and persists updates. It checks common suppression and also directly checks `@syncing`, which is redundant with common suppression but documents local intent. `@erasing` prevents lifecycle erases from re-entering change handling. No relocating, finishing, or constraining check is present. |
| `cell_space_closed` | Yes | No | Yes | No | No | Close routing recenters and marks topology dirty after CellSpace geometry edits. It checks common suppression plus direct `@syncing` and `@erasing`. No direct relocating or finish guard exists. Needs confirmation: whether CellSpace close callbacks can fire during primal normalization and should be suppressed by relocating is not confirmed by tests. |
| `cell_space_erased` | Yes | No | Yes | No | No | Erase routing removes CellSpace runtime state while preserving the SketchUp group when called from the observer. Common suppression avoids replay and sync paths; `@erasing` prevents lifecycle erases from recursively erasing runtime. |
| `space_features_erased` | No | No | No | No | No | This route only clears cached primal references, observer keys, and scene-group tracking. It intentionally has no suppression in current code. Needs confirmation: there is no focused test proving guard behavior for this cleanup-only route. |

## Guard Ownership Notes

| Guard | Owner | Current intent | Verified by |
|---|---|---|---|
| `@relocating_entity` | `EntityRelocation`, `PrimalNormalization` | Suppress add/remove routing caused by extension-owned entity parent/context moves. | `test_reentrant_relocation_return_preserves_outer_relocation_guard`, `test_primal_normalization_preserves_existing_relocation_guard` |
| `@erasing` | `RuntimeSupport#erase_guard`, `FeatureLifecycle#erase_cell_space` | Suppress callbacks caused by extension-owned runtime erase operations. | Route suppression covered in `test_observer_routing_guards.rb`; full owner lifecycle is not separately asserted. |
| `@finishing_editing` | `EditorControl#finish_editing` | Suppress SpaceFeatures change routing while edit mode finishes and primal normalization runs. | `test_finish_editing_preserves_existing_finish_guard`; semantic suppression is covered by route code, not a focused repro test. |
| `@constraining_space_features` | `ObserverRouting#handle_space_features_name_changed`, `#reject_scaled_space_features_transform`, `RuntimeSupport#with_space_feature_constraint` | Prevent constraint enforcement from recursively handling the change it creates. | Code inspection and `space_features_changed` route tests; no focused transform-reentry test. |
| `@refreshing_runtime` | `RuntimeSupport#refresh_runtime_data` | Prevent nested runtime refresh. Observer suppression during refresh is owned by the nested `sync` block, not by checking `@refreshing_runtime` in observer routes. | `test_nested_refresh_does_not_release_outer_refresh_guard` |

## Known Unconfirmed Areas

| Area | Status |
|---|---|
| CellSpace close callbacks during primal normalization | Needs confirmation: current code does not check `@relocating_entity` in `cell_space_closed`, and tests do not prove whether SketchUp emits this callback during normalization. |
| `space_features_erased` guard behavior | Needs confirmation: route is cleanup-only and intentionally unguarded in code, but no focused test asserts this. |
| Finish-editing normalization runtime reconciliation | Needs confirmation: code has a disabled `refresh_runtime_data` comment and normalization runs under `@relocating_entity`; GUI reproduction is required before changing runtime behavior. |
