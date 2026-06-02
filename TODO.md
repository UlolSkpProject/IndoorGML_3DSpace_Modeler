# TODO

## Cleanup

- Review whether `DualentitiesObserver` is still needed, then remove it if obsolete.
- Review whether `StateObserver` is still needed, then remove it if obsolete.
- Remove other deprecated code paths.
- Check and document the responsibilities of the `IndoorModel` mixins:
  - `RuntimeSupport`
  - `SceneGroups`
  - `FeatureLifecycle`
  - `Topology`
  - `ObserverRouting`
  - `EntityRelocation`
  - `EditorControl`
- Re-check any remaining `restore_name`/message text encoding issues.
- Remove unnecessary attributes from `FeatureRegistry`.

## Export

- Decide and implement whether exported XML should use concrete IndoorGML space tags instead of always using `core:CellSpace`.
  - Current behavior: all spaces are exported as `<core:CellSpace>`.
  - Required direction: map internal `cell_type` to XML element names such as `GeneralSpace`, `TransitionSpace`, `AnchorSpace`, and `ConnectionSpace` where supported by the target IndoorGML schema/profile.
