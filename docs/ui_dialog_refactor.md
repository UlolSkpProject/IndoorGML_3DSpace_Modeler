# Refactor Task: Extract HTML/CSS/JS from Ruby Dialog Classes

## Context

This is a SketchUp Ruby extension (Indoor3DGML Modeler).
Two Ruby files currently embed large HTML/CSS/JS strings inline as heredocs:

- `indoor3d/classes/IndoorCore/services/EditModeDialog.rb`
- `indoor3d/classes/IndoorCore/services/indoor_gml_converter/export_progress_dialog.rb`

The goal is to extract the HTML/CSS/JS into separate files and load them via `UI::HtmlDialog#set_file`.

---

## Target File Structure

```
indoor3d/
└── ui/
    ├── edit_mode_dialog.rb
    ├── export_progress_dialog.rb
    └── html/
        ├── edit_mode/
        │   ├── index.html
        │   ├── style.css
        │   └── app.js
        └── export_progress/
            ├── index.html
            ├── style.css
            └── app.js
```

Move the two Ruby files from their current locations to `indoor3d/ui/`.
Update `require_relative` references in `indoor3d/classes/IndoorCore/IndoorCore.rb` accordingly.

---

## Rules

1. **Do not change any logic.** All Ruby callback behavior, JS functions, and CSS styles must remain identical to the original.
2. **Use `set_file` instead of `set_html`.** Replace the `show` method's `dialog.set_html(html)` call with `dialog.set_file(File.join(__dir__, 'html', 'edit_mode', 'index.html'))`.
3. **Dynamic values must be injected via `execute_script` after load.** Since `set_file` renders before Ruby can inject values, use the `domReady` callback pattern:
   - In `index.html`, add at the end of `<script>`: `window.addEventListener('load', function() { sketchup.domReady(); });`
   - In the Ruby dialog builder, add: `dialog.add_action_callback('domReady') { dialog.execute_script("init(...)") }`
   - Define an `init(minRadius, maxRadius, classificationOptionsJson)` function in `app.js` that populates the `<select>` and sets slider values.
4. **CSS and JS must be referenced as relative paths** from `index.html`:
   ```html
   <link rel="stylesheet" href="style.css">
   <script src="app.js"></script>
   ```
5. **Remove the `html` private method** from both Ruby classes after extraction.
6. **`export_progress_dialog.rb`**: The `STEPS` constant and step labels are defined in Ruby. Pass them to JS via `execute_script` after `domReady`, or embed them as a JSON literal in `index.html` using a `<script>` block — do not hardcode them in `app.js`.
7. **Do not modify any other files** except the four listed below plus the two new html directories.

---

## Files to Modify

| File | Action |
|------|--------|
| `indoor3d/classes/IndoorCore/services/EditModeDialog.rb` | Move to `indoor3d/ui/edit_mode_dialog.rb`, apply `set_file` pattern |
| `indoor3d/classes/IndoorCore/services/indoor_gml_converter/export_progress_dialog.rb` | Move to `indoor3d/ui/export_progress_dialog.rb`, apply `set_file` pattern |
| `indoor3d/classes/IndoorCore/IndoorCore.rb` | Update `require_relative` paths for both dialog files |
| `indoor3d/ui/html/edit_mode/index.html` | New file — extracted markup |
| `indoor3d/ui/html/edit_mode/style.css` | New file — extracted styles |
| `indoor3d/ui/html/edit_mode/app.js` | New file — extracted scripts |
| `indoor3d/ui/html/export_progress/index.html` | New file — extracted markup |
| `indoor3d/ui/html/export_progress/style.css` | New file — extracted styles |
| `indoor3d/ui/html/export_progress/app.js` | New file — extracted scripts |

---

## Acceptance Criteria

- [ ] `EditModeDialog#show` calls `set_file`, not `set_html`
- [ ] `ExportProgressDialog#show` calls `set_file`, not `set_html`
- [ ] No inline HTML strings remain in either Ruby file
- [ ] `html` private method is deleted from both Ruby files
- [ ] Slider initial values and classification `<select>` options are populated via `execute_script` after `domReady`
- [ ] `ExportProgressDialog#set_status` still works by calling `execute_script("setStatus(...)")`  
- [ ] `EditModeDialog#update_selection` still works by calling `execute_script("updateSelectedCellSpace(...)")`
- [ ] CSS and JS load correctly via relative paths from `index.html`
- [ ] `require_relative` paths in `IndoorCore.rb` are updated and correct
- [ ] No other files are modified