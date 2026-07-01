# Golden GML Baseline

This baseline records the current exporter output before staged architecture refactors.

## Source Model

- Model: current SketchUp model open during PR 01 baseline capture.
- SKP files are not committed because `*.skp` is ignored.
- The committed GML is a canonicalized export from that open model.

## Files

- Golden GML: `fixtures/golden/current_model.gml`
- Canonicalizer: `scripts/canonicalize_gml.rb`
- Val3dity stdout fixtures:
  - `fixtures/val3dity/current_model.log`
  - `fixtures/val3dity/success.log`
  - `fixtures/val3dity/overlap.log`
  - `fixtures/val3dity/failure.log`

## Current Validation Baseline

The current model baseline is not fully valid under strict val3dity.

- val3dity process exit code: `0`
- feature validity: invalid
- primitive validity: 218 / 220 valid
- extension-visible error codes: `203`, `701`
- raw CLI fixture also contains `704` in the strict summary

This is a model-state baseline, not a requirement that every refactor PR makes the model valid.

## Refresh Procedure

1. Open the intended baseline model in SketchUp.
2. Refresh IndoorGML runtime data.
3. Export GML with the extension exporter.
4. Run:

   ```sh
   ruby scripts/canonicalize_gml.rb path/to/export.gml fixtures/golden/current_model.gml
   ```

5. Compare the resulting diff. Expected refactor-only PRs should not change this file unless the PR explicitly updates the exporter baseline.

## Manual Smoke Checklist

Use this checklist after each PR that touches runtime behavior:

- Extension loads without Ruby Console exceptions.
- `IndoorModel.current.diagnostic_snapshot` returns counts and all guard flags are false at rest.
- CellSpace create/delete still works.
- type and Storey edits still persist.
- adjacency Transition creation/removal still works.
- EditMode starts and finishes.
- Export GML completes and active path returns to the previous state.
- Check Validity completes or fails with the same known model-level validity result.

Undo/Redo instability that is already documented remains deferred unless the PR directly changes Undo/Redo behavior.
