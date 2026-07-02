# Active Path Ownership

`Sketchup::Model#active_path` is mutable SketchUp editor state. It is allowed in this extension, but each use case must restore it deliberately.

## Current Use Cases

| Use case | Current owner | Policy |
| --- | --- | --- |
| EditMode enter/finish/enforcement | `EditorSession` | Keep local until EditSession controllers are extracted. |
| GML export root-coordinate read | `GmlExporter` via `ActivePathController` | Snapshot, close to root, export, restore. |
| UI conversion commands | `BaseCommands` via `ActivePathController` | Snapshot, close to root, restore only when there was an original path. |
| active path observer callback | `IndoorModel#active_path_changed` / `EditorSession` | Route to edit-mode state handling. |

## Primitive

`ActivePathController` is the minimum shared primitive for:

- `snapshot`
- `close_to_root`
- `restore`
- `set`
- `matches?`

It does not own EditMode state. `EditorSession` still owns edit target tracking and enforcement until the later EditorSession split PRs.

## Rules

- New code should not call `model.active_path = ...` directly unless it is inside `EditorSession` or `ActivePathController`.
- Export-like reads should close to root inside a restore guard.
- UI commands that temporarily leave an edit context should restore only a non-empty original path.
- Undo/Redo active path repair is intentionally deferred to the later EditSession/active-path cleanup work.
