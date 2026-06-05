# Refactor Task: Restructure File Layout

## Context

This is a SketchUp Ruby extension (Indoor3DGML Modeler).
The goal is to **reorganize the file and folder structure only** — no logic, class, method, or content changes.

All `require_relative` paths must be updated to match the new locations.

---

## Current Structure

```
indoor3d.rb
indoor3d/
├── core.rb
├── utils/
│   ├── geometry.rb
│   ├── transformation.rb
│   ├── materials.rb
│   └── html_helpers.rb
└── classes/
    └── IndoorCore/
        ├── IndoorCore.rb
        ├── IndoorModel.rb
        ├── Observers.rb
        ├── features/
        │   ├── abstract_feature.rb
        │   ├── cell_space.rb
        │   ├── cell_space_type.rb
        │   ├── cell_space_category.rb
        │   ├── state.rb
        │   └── transition.rb
        ├── observers/
        │   ├── observer_helpers.rb
        │   ├── app_observer.rb
        │   ├── model_observer.rb
        │   ├── cell_space_observer.rb
        │   ├── space_features_observer.rb
        │   ├── root_entities_observer.rb
        │   ├── primal_entities_observer.rb
        │   └── selection_observer.rb
        ├── overlays/
        │   └── edit_mode_overlay.rb
        └── services/
            ├── AttributeSerializer.rb
            ├── FeatureRegistry.rb
            ├── AdjacencyService.rb
            ├── RuntimeRestorer.rb
            ├── SceneGroupGuard.rb
            ├── EditorSession.rb
            ├── EditModeDialog.rb
            └── indoor_model/
            │   ├── runtime_support.rb
            │   ├── scene_groups.rb
            │   ├── feature_lifecycle.rb
            │   ├── topology.rb
            │   ├── observer_routing.rb
            │   ├── entity_relocation.rb
            │   └── editor_control.rb
            └── indoor_gml_converter/
                ├── gml_exporter.rb
                ├── val3dity_runner.rb
                └── export_progress_dialog.rb
```

---

## Target Structure

```
indoor3d.rb
indoor3d/
├── core.rb
├── domain/
│   ├── abstract_feature.rb
│   ├── cell_space.rb
│   ├── cell_space_type.rb
│   ├── cell_space_category.rb
│   ├── state.rb
│   └── transition.rb
├── application/
│   ├── indoor_model.rb
│   ├── feature_registry.rb
│   ├── adjacency_service.rb
│   └── indoor_model/
│       ├── runtime_support.rb
│       ├── scene_groups.rb
│       ├── feature_lifecycle.rb
│       ├── topology.rb
│       ├── observer_routing.rb
│       ├── entity_relocation.rb
│       └── editor_control.rb
├── infrastructure/
│   ├── observers/
│   │   ├── observer_helpers.rb
│   │   ├── app_observer.rb
│   │   ├── model_observer.rb
│   │   ├── cell_space_observer.rb
│   │   ├── space_features_observer.rb
│   │   ├── root_entities_observer.rb
│   │   ├── primal_entities_observer.rb
│   │   └── selection_observer.rb
│   ├── persistence/
│   │   ├── attribute_serializer.rb
│   │   └── runtime_restorer.rb
│   └── scene/
│       ├── scene_group_guard.rb
│       └── editor_session.rb
├── export/
│   ├── gml_exporter.rb
│   ├── val3dity_runner.rb
│   └── export_progress_dialog.rb
├── ui/
│   ├── edit_mode_dialog.rb
│   ├── edit_mode_overlay.rb
│   └── html/
│       ├── edit_mode/
│       │   ├── index.html
│       │   ├── style.css
│       │   └── app.js
│       └── export_progress/
│           ├── index.html
│           ├── style.css
│           └── app.js
└── utils/
    ├── geometry.rb
    ├── transformation.rb
    ├── materials.rb
    └── html_helpers.rb
```

---

## Rename Map

| Old path | New path |
|----------|----------|
| `indoor3d/classes/IndoorCore/features/abstract_feature.rb` | `indoor3d/domain/abstract_feature.rb` |
| `indoor3d/classes/IndoorCore/features/cell_space.rb` | `indoor3d/domain/cell_space.rb` |
| `indoor3d/classes/IndoorCore/features/cell_space_type.rb` | `indoor3d/domain/cell_space_type.rb` |
| `indoor3d/classes/IndoorCore/features/cell_space_category.rb` | `indoor3d/domain/cell_space_category.rb` |
| `indoor3d/classes/IndoorCore/features/state.rb` | `indoor3d/domain/state.rb` |
| `indoor3d/classes/IndoorCore/features/transition.rb` | `indoor3d/domain/transition.rb` |
| `indoor3d/classes/IndoorCore/IndoorModel.rb` | `indoor3d/application/indoor_model.rb` |
| `indoor3d/classes/IndoorCore/services/FeatureRegistry.rb` | `indoor3d/application/feature_registry.rb` |
| `indoor3d/classes/IndoorCore/services/AdjacencyService.rb` | `indoor3d/application/adjacency_service.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_model/runtime_support.rb` | `indoor3d/application/indoor_model/runtime_support.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_model/scene_groups.rb` | `indoor3d/application/indoor_model/scene_groups.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_model/feature_lifecycle.rb` | `indoor3d/application/indoor_model/feature_lifecycle.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_model/topology.rb` | `indoor3d/application/indoor_model/topology.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_model/observer_routing.rb` | `indoor3d/application/indoor_model/observer_routing.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_model/entity_relocation.rb` | `indoor3d/application/indoor_model/entity_relocation.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_model/editor_control.rb` | `indoor3d/application/indoor_model/editor_control.rb` |
| `indoor3d/classes/IndoorCore/observers/observer_helpers.rb` | `indoor3d/infrastructure/observers/observer_helpers.rb` |
| `indoor3d/classes/IndoorCore/observers/app_observer.rb` | `indoor3d/infrastructure/observers/app_observer.rb` |
| `indoor3d/classes/IndoorCore/observers/model_observer.rb` | `indoor3d/infrastructure/observers/model_observer.rb` |
| `indoor3d/classes/IndoorCore/observers/cell_space_observer.rb` | `indoor3d/infrastructure/observers/cell_space_observer.rb` |
| `indoor3d/classes/IndoorCore/observers/space_features_observer.rb` | `indoor3d/infrastructure/observers/space_features_observer.rb` |
| `indoor3d/classes/IndoorCore/observers/root_entities_observer.rb` | `indoor3d/infrastructure/observers/root_entities_observer.rb` |
| `indoor3d/classes/IndoorCore/observers/primal_entities_observer.rb` | `indoor3d/infrastructure/observers/primal_entities_observer.rb` |
| `indoor3d/classes/IndoorCore/observers/selection_observer.rb` | `indoor3d/infrastructure/observers/selection_observer.rb` |
| `indoor3d/classes/IndoorCore/services/AttributeSerializer.rb` | `indoor3d/infrastructure/persistence/attribute_serializer.rb` |
| `indoor3d/classes/IndoorCore/services/RuntimeRestorer.rb` | `indoor3d/infrastructure/persistence/runtime_restorer.rb` |
| `indoor3d/classes/IndoorCore/services/SceneGroupGuard.rb` | `indoor3d/infrastructure/scene/scene_group_guard.rb` |
| `indoor3d/classes/IndoorCore/services/EditorSession.rb` | `indoor3d/infrastructure/scene/editor_session.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_gml_converter/gml_exporter.rb` | `indoor3d/export/gml_exporter.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_gml_converter/val3dity_runner.rb` | `indoor3d/export/val3dity_runner.rb` |
| `indoor3d/classes/IndoorCore/services/indoor_gml_converter/export_progress_dialog.rb` | `indoor3d/export/export_progress_dialog.rb` |
| `indoor3d/classes/IndoorCore/services/EditModeDialog.rb` | `indoor3d/ui/edit_mode_dialog.rb` |
| `indoor3d/classes/IndoorCore/overlays/edit_mode_overlay.rb` | `indoor3d/ui/edit_mode_overlay.rb` |

The old `indoor3d/classes/IndoorCore/IndoorCore.rb` and `indoor3d/classes/IndoorCore/Observers.rb`
are replaced by a new loader file at `indoor3d/application/indoor_model.rb` — see the require list below.

---

## HTML Extraction (EditModeDialog and ExportProgressDialog)

The two dialog files contain inline HTML/CSS/JS heredocs.
Extract them into the `ui/html/` directory and load via `UI::HtmlDialog#set_file`.

### EditModeDialog

- Extract the `html` method's heredoc into:
  - `indoor3d/ui/html/edit_mode/index.html` — markup only
  - `indoor3d/ui/html/edit_mode/style.css` — all `<style>` content
  - `indoor3d/ui/html/edit_mode/app.js` — all `<script>` content
- In `edit_mode_dialog.rb`:
  - Replace `dialog.set_html(html)` with `dialog.set_file(File.join(__dir__, 'html', 'edit_mode', 'index.html'))`
  - Add a `domReady` callback that calls `execute_script("init(minRadius, maxRadius, optionsJson)")`
  - Delete the `html` private method
- In `index.html`: add `<link rel="stylesheet" href="style.css">` and `<script src="app.js"></script>`
- In `app.js`: add an `init(minRadius, maxRadius, optionsJson)` function that populates the `<select>` and sets slider values; fire `sketchup.domReady()` on `window load`

### ExportProgressDialog

- Extract into `export_progress/index.html`, `style.css`, `app.js` the same way
- The `STEPS` constant is defined in Ruby — pass step data to JS via `execute_script` in the `domReady` callback; do not hardcode steps in `app.js`
- `set_status(step, status)` must still work via `execute_script("setStatus(...)")`

---

## require_relative Update Rules

- Every `require_relative` in every file must reflect the new path.
- The old `IndoorCore.rb` loader is deleted. Its role is replaced by `indoor3d/core.rb`, which must require all files in dependency order:

```ruby
# indoor3d/core.rb  — suggested require order
require_relative 'utils/html_helpers'
require_relative 'utils/geometry'
require_relative 'utils/transformation'
require_relative 'utils/materials'
require_relative 'domain/abstract_feature'
require_relative 'domain/cell_space_type'
require_relative 'domain/cell_space_category'
require_relative 'domain/cell_space'
require_relative 'domain/state'
require_relative 'domain/transition'
require_relative 'infrastructure/observers/observer_helpers'
require_relative 'infrastructure/observers/cell_space_observer'
require_relative 'infrastructure/observers/space_features_observer'
require_relative 'infrastructure/observers/root_entities_observer'
require_relative 'infrastructure/observers/primal_entities_observer'
require_relative 'infrastructure/observers/selection_observer'
require_relative 'infrastructure/observers/model_observer'
require_relative 'infrastructure/observers/app_observer'
require_relative 'infrastructure/persistence/attribute_serializer'
require_relative 'infrastructure/persistence/runtime_restorer'
require_relative 'infrastructure/scene/scene_group_guard'
require_relative 'infrastructure/scene/editor_session'
require_relative 'application/feature_registry'
require_relative 'application/adjacency_service'
require_relative 'application/indoor_model/runtime_support'
require_relative 'application/indoor_model/scene_groups'
require_relative 'application/indoor_model/feature_lifecycle'
require_relative 'application/indoor_model/topology'
require_relative 'application/indoor_model/observer_routing'
require_relative 'application/indoor_model/entity_relocation'
require_relative 'application/indoor_model/editor_control'
require_relative 'application/indoor_model'
require_relative 'export/gml_exporter'
require_relative 'export/val3dity_runner'
require_relative 'export/export_progress_dialog'
require_relative 'ui/edit_mode_overlay'
require_relative 'ui/edit_mode_dialog'
```

---

## Rules

1. **No logic changes.** Move and rename files only. Do not modify any method, class, module name, constant, or behavior.
2. **Module/class names stay the same.** e.g. `ULOL::Indoor3DGmlModeler::IndoorCore::AdjacencyService` keeps its full namespace regardless of where the file lives.
3. **Delete old files and folders** after moving. The entire `indoor3d/classes/` directory must be gone when done.
4. **`require_relative` paths must be correct** from each file's new location.
5. **`indoor3d/classes/IndoorCore/IndoorCore.rb` and `Observers.rb` are deleted** — their require lists are consolidated into `indoor3d/core.rb`.
6. **File name casing**: use `snake_case` for all new filenames (the rename map above already reflects this).

---

## Acceptance Criteria

- [ ] `indoor3d/classes/` directory no longer exists
- [ ] All files exist at the paths listed in the rename map
- [ ] All `require_relative` references resolve correctly from each file's new location
- [ ] `indoor3d/core.rb` requires all files in the correct dependency order
- [ ] No inline HTML heredocs remain in `edit_mode_dialog.rb` or `export_progress_dialog.rb`
- [ ] `UI::HtmlDialog#set_file` is used in both dialog files
- [ ] All module/class names are unchanged
- [ ] The extension loads without error in SketchUp