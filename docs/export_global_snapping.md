# IndoorGML export global vertex snapping

Val3dity validates the coordinates written to the GML file. It does not know that two
SketchUp vertices from different groups were intended to be the same point if their
exported world coordinates differ by a small transform/export artifact.

The exporter therefore canonicalizes CellSpace solid vertices before writing
`gml:pos` values. This is a preprocessing step for SketchUp export coordinates. It is
not a replacement for val3dity's `overlap_tol`, and the validation runner still does
not pass `--overlap_tol`. The runner also does not pass `--snap_tol`; val3dity keeps
its default `snap_tol` value.

## Export flow

1. Export closes the active edit path so CellSpace transforms are evaluated from the
   model root.
2. Each exportable CellSpace group's transform is accumulated with the
   `IndoorGML_PrimalSpaceFeatures` transform when the CellSpace is a direct child of
   that root group.
3. All CellSpace face loop vertices are transformed to world coordinates and inserted
   into one global `GlobalSnappingMap`.
4. When surfaces are written, each face/ring vertex is looked up in the same map and
   the canonical coordinate is written to GML.

## Snapping policy

`GlobalSnappingMap` uses a distance-based spatial hash, not decimal-place rounding.

- Grid cell size is the snap tolerance.
- A vertex searches its own grid cell and the 26 adjacent cells.
- A candidate is reused only when the actual 3D Euclidean distance is within the
  tolerance.
- The first vertex inserted into a cluster remains the canonical coordinate.

The first-coordinate policy avoids moving an established face plane by a running
centroid or average. A later face-plane projection policy can be added separately if
needed.

## Tolerance and diagnostics

The initial exporter tolerance is `1e-6` model units. It should be larger than
transform/export noise and smaller than intentional small details, thin walls, or real
gaps.

Export logs include:

- input vertex count
- canonical vertex count
- merged vertex count
- maximum vertex displacement
- degenerate ring warnings when snapping collapses a face ring below 3 unique vertices

Coordinates are written with 17 significant digits so the canonicalized coordinates are
not rounded back into ambiguous values during serialization.

## Raw world-coordinate export

Global snapping is selectable. The default/export-recommended mode is enabled, but
`GmlExporter.new(..., global_snapping: false)` keeps the previous raw world-coordinate
flow for diagnosis and comparison. In raw mode, CellSpace vertices are still transformed
to export/world coordinates, but they are not passed through the global
`GlobalSnappingMap`.

The toolbar export and validity commands ask whether to use global vertex snapping
before creating the GML.
