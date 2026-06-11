# Coplanar Face Adjacency Notes

## Purpose

This note records the geometry experiments for improving dual graph transition visualization.

The goal is not to highlight adjacency faces. The goal is to find a geometric waypoint candidate for a transition between two connected nodes. The waypoint candidate comes from the common face area between two CellSpace solids.

## Scope

The implementation target is:

- Find common face candidates between two CellSpace solids.
- Use the center of a selected common face candidate as a transition waypoint candidate.
- If multiple maximum-area candidates exist, keep all of them until a route-selection rule chooses one.

Out of scope:

- 3D overlay highlight for adjacency evidence.
- Permanent material painting of common faces.
- Automatic support for CellSpace completely inside another CellSpace.

## Coordinate Policy

All common-face calculations should be performed in world coordinates.

Reason:

- Source faces can live inside nested groups.
- CellSpace groups may have transformations.
- Previous extension work has repeatedly exposed ambiguity between local, active-context, primal-space, and world coordinates.

Recommended flow:

1. Read face vertices from each source group.
2. Transform vertices to world coordinates.
3. Compute common face candidates in world coordinates.
4. Compute waypoint candidates in world coordinates.
5. Convert to another coordinate space only at the final storage/rendering boundary if required.

## Planar Common Face Detection

For two solids, compare face pairs from solid A and solid B.

For each face pair:

1. Transform both faces to world coordinates.
2. Check that normals are parallel.
3. Check that all vertices of face B lie on the plane of face A within tolerance.
4. If the pair is coplanar, create temporary scratch geometry.
5. Add both world-space faces into the scratch group.
6. Run `Entities#intersect_with` on the scratch entities.
7. Inspect the split scratch faces.
8. A split face is accepted only if all of these sample points are inside both original polygons:
   - every outer-loop vertex
   - every outer-loop edge midpoint
   - face centroid
9. Remove duplicate accepted polygons.
10. Return all accepted common face candidates.

Important lesson from testing:

- Centroid-only classification is unsafe.
- It can select a larger face whose centroid lies inside the overlap even when parts of the face are outside.
- Vertex, midpoint, and centroid checks were needed to reject those false positives.

## Candidate Selection

Common face candidates are sorted by area.

If the maximum area is unique:

- Use that face as the primary common face candidate.

If several candidates have the same maximum area within tolerance:

- Return all maximum-area candidates.
- Do not silently choose the first one.

This is required for segmented or curved contact cases, where several equal-area patches can represent one contact band.

## Waypoint Candidate

For a planar common face candidate:

- The transition waypoint candidate should be the polygon centroid of the common face.
- Do not use a plain vertex average unless the polygon is known to be a rectangle.

For implementation, triangulate the polygon and use an area-weighted polygon centroid:

1. Use the first vertex as a fan origin.
2. For each triangle, compute triangle area and centroid.
3. Compute `sum(triangle_centroid * triangle_area) / sum(triangle_area)`.

The result is in world coordinates.

## Curved Or Segmented Contact

IndoorGML 1.0 does not imply that CellSpace adjacency must only occur through one planar face. However, this SketchUp extension currently works with polygonal faces. A curved wall is represented as many small planar faces.

In such cases, common face detection can return many planar patches:

```text
common patch 1
common patch 2
common patch 3
...
```

These patches can represent one curved contact band.

## Patch Clustering

For curved or segmented contact, patches should be grouped into clusters when they are part of the same contact band.

Initial clustering rule:

- Two common face patches belong to the same cluster if they share an edge or touch within tolerance.

For each cluster:

1. Compute each patch polygon centroid.
2. Compute each patch area.
3. Compute the area-weighted centroid of the cluster.

However, the cluster area-weighted centroid is only a reference point. On a curved contact band, this point can float in space and may not lie on any actual patch.

## Curved Contact Waypoint Policy

For curved or segmented contact, do not use the cluster area-weighted centroid directly as the transition waypoint.

Recommended policy:

1. Compute the cluster area-weighted centroid.
2. Find the patch centroid closest to that area-weighted centroid.
3. Use that patch centroid as the waypoint candidate.

This keeps the waypoint on an actual face while still choosing a representative patch near the middle of the contact band.

Terms:

- `cluster_centroid`: area-weighted reference point; not guaranteed to lie on a face.
- `waypoint_candidate`: actual point used by transition routing; must lie on a selected patch face.

## Test Observations

### face_group1

- Two named child groups, each with one face.
- Common face was a rectangular overlap.
- Simple polygon intersection worked.

### face_group2

- One face was fully contained in the other.
- The common face was the smaller contained face.

### face_group3

- Two solid child groups.
- Initial centroid-only scratch-face classification incorrectly selected a larger face.
- Corrected sample-point classification found the true common face.

### face_group4

- Multiple common face candidates were found.
- The largest area candidate was unique.

### face_group5

- Initial polygon clipping result was wrong for the tested shape.
- Scratch split plus vertex, midpoint, and centroid classification found two equal maximum-area candidates.
- This confirmed that maximum-area ties must be returned as a list.

### face_group6

- After retesting the current model state, several coplanar pairs existed.
- Three common face candidates were found.
- The largest area candidate was unique.

### face_group7

- Segmented or curved-like contact case.
- Ten common face intersections were found.
- Eight candidates had effectively the same maximum area.
- Area-weighted centroid of those eight patches was computed.
- The nearest patch centroid to that weighted centroid was selected as a face-safe representative waypoint candidate.

## Open Questions

- How should patches be clustered when they are near each other but do not share an exact edge?
- What tolerance should be used for coplanarity, point-in-polygon, and patch clustering?
- Should curved contact return one cluster waypoint or several route candidates?
- How should existing transition data store optional waypoint candidates?
