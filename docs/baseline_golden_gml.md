# Golden GML Baseline

The repository no longer tracks local Golden GML, SKP, val3dity stdout, or helper script artifacts.

## Source Model

- Model: current SketchUp model selected by the developer during local validation.
- SKP, exported GML, and val3dity stdout logs are local artifacts and are ignored.

## Files

- No baseline fixture files are tracked in Git.

## Current Validation Baseline

The current model baseline is not fully valid under strict val3dity.

- val3dity process exit code: `0`
- feature validity: invalid
- primitive validity: 218 / 220 valid
- extension-visible error codes: `203`, `701`
- raw CLI fixture also contains `704` in the strict summary

This was a model-state baseline, not a requirement that every refactor PR makes the model valid.

## Refresh Procedure

1. Open the intended baseline model in SketchUp.
2. Refresh IndoorGML runtime data.
3. Export GML with the extension exporter.
4. Compare export output locally when needed. Expected refactor-only PRs should not change exporter output unless the PR explicitly updates exporter behavior.

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
