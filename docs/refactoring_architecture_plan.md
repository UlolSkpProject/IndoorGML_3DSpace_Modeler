# IndoorGML 3D Space Modeler Refactoring Plan

This document is the working standard for the staged architecture refactor. Each stage must be handled as a separate branch and PR unless explicitly superseded by a later decision.

## Core Principles

- SketchUp API usage is allowed. The goal is to control ownership of mutable SketchUp state, not to hide every SketchUp type.
- `IndoorModel` remains the model-level runtime context and facade, but implementation responsibilities should move to focused collaborators over time.
- Ruby mixins are not banned. Existing mixins should be strangled gradually by moving implementation into services, then deleting empty mixins.
- Do not merge concepts only because they use the same SketchUp API. Storey filters, Storey persistence normalization, export active-path scope, and edit-mode active-path enforcement have different contracts.
- Extract a new object only when it has independent state, a distinct reason to change, a lifecycle/restore responsibility, repeated policy, clear test value, or replaceable implementation.

## PR Workflow

Every PR follows this loop:

```text
planning -> review -> approval loop -> implementation -> inspection -> fix loop -> commit
```

Rules:

- Start from `main` or the previously approved refactor branch state.
- Use `refactor/prXX-short-topic` branch names, except PR 00 which uses `refactor/architecture-diagnostics`.
- Keep the PR scope limited to the approved stage.
- Keep behavior and public APIs stable unless the PR explicitly says otherwise.
- Do not combine unrelated architecture moves in one PR.
- Commit only after checks pass.

## Common Inspection Gate

Run the narrowest meaningful checks for each PR:

- `ruby -c` on changed Ruby files.
- Ruby syntax checks and SketchUp HTTP smoke checks. Local scripts/fixtures are not tracked in Git.
- `rg` checks for stage-specific forbidden patterns.
- SketchUp HTTP smoke checks when SketchUp runtime behavior is touched:
  - `GET /ping`
  - `GET /model/summary`
  - `POST /eval` for `IndoorModel.current.diagnostic_snapshot` when available.

Undo/Redo instability that is already documented as deferred should be recorded, but it does not block unrelated structural PRs unless the PR directly changes that behavior.

## PR Sequence

```text
PR 00  Architecture baseline and diagnostic snapshot
PR 01  Golden GML and smoke checklist baseline
PR 02  StoreyFilterParser/OptionsBuilder
PR 03  RuntimeRestorer keyword callback
PR 04  Val3dityOutputParser extraction
PR 05  Val3dityProcessAdapter extraction and Win32 constants
PR 06  Val3dityReportSchema and shared helper
PR 07  ValidationReportRenderer extraction
PR 08  OverlapRecheckPolicy extraction
PR 09  Val3dityRunner orchestration cleanup
PR 10  Remaining private boundary violations
PR 11  EditorControl projection extraction
PR 12  Active path usage matrix and minimal primitives
PR 13  VisibilityController
PR 14  EditLockController
PR 15  OverlayController
PR 16  ValidationFocusSession
PR 17  Entity clone case matrix and minimal helpers
PR 18  CellSpaceLifecycleService
PR 19  FeatureLifecycle delegation
PR 20  ExportSnapshotBuilder
PR 21  GmlWriter extraction
PR 22  Empty mixin and unnecessary forwarding cleanup
```

## Stage Boundaries

- Storey UI filtering may be shared between `EditorSession` and `EditorControl`; do not merge it with `CellSpace#normalize_storey`.
- Runtime restore callback hash should become explicit keyword arguments before adding more restore collaborators.
- `Val3dityRunner` is split in small steps. Do not move process execution, parser, renderer, overlap policy, and orchestration in one PR.
- Active path work starts with a usage matrix. Do not immediately merge exporter scoped active path handling and edit-mode long-lived enforcement into one generic controller.
- Entity cloning starts with a usage matrix. Share only identical primitives, not a single large clone service.
- Export snapshot work must make the XML writer independent of live SketchUp model reads.

## PR 00 Scope

PR 00 establishes the baseline for future stages:

- Add `IndoorModel#diagnostic_snapshot` for manual and SketchUp HTTP smoke inspection.
- Replace the known `EditorSession` private `send(:with_guard_flag, ...)` call with a named public collaboration method.
- Record SketchUp state ownership and extraction rules in architecture docs.
- Add this staged refactoring plan as the repository-level operating standard.
