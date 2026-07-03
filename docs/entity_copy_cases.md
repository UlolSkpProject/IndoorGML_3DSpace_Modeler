# Entity Copy Cases

PR17 introduces `IndoorCore::EntityCopyHelper` as the minimum shared primitive for SketchUp entity copy operations. The helper only centralizes the mechanical copy step:

- `target_entities.add_instance(source.definition, transformation)`
- optional `to_group`
- optional `make_unique`
- optional copy of `name`, `material`, `layer`, and `visible`
- optional IndoorGML attribute copy callback

It does not calculate transformations, choose the target collection, erase the source, or decide whether a copied entity should become a CellSpace. Those remain owned by each use case.

## Applied In PR17

- `IndoorModel::SceneGroups#clone_group_under_primal_space`
  - Keeps the existing behavior of converting any supported copy to a group and making it unique.
- `IndoorModel::EntityRelocation#copy_entity_to_entities`
  - Keeps group-only `to_group` and `make_unique`.
  - Keeps name/material copy and IndoorGML attribute copy.
- `IndoorModel::FeatureLifecycle#convert_primal_child_to_cell_space`
  - Keeps group-only `to_group` and `make_unique`.
  - Keeps name/material/layer/visible copy.
- `IndoorCore::CellSpaceConversionExecutor`
  - Keeps group-only `to_group` and `make_unique`.
  - Keeps name/material/layer/visible copy.

## Deferred Cases

- `IndoorModel::PrimalNormalization`
  - It contains active-path and primal wrapping normalization logic. Apply the helper after that flow has dedicated coverage.
- `ui/commands/cell_space_commands.rb`
  - The toolbar conversion path now uses `CellSpaceConversionExecutor`, which delegates mechanical copying to `EntityCopyHelper`.
- `FeatureLifecycle#make_cell_space_entity_unique`
  - This is not a copy operation. It repairs copied CellSpace identity and should remain separate.

## Boundary Rule

New code should prefer `EntityCopyHelper.copy_instance` for the mechanical instance-copy step. Transformation math and source cleanup must stay in the owning use case until a broader CellSpace lifecycle service exists.
