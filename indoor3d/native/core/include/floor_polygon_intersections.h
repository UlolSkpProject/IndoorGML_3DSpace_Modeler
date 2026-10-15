#pragma once
#include "floor_polygon_preparation.h"

#include <cstddef>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
// Phase 3: geometric intersections ONLY; no topological edits.
enum class Location { Outside, Inside, Boundary };
enum class TraceError {
    None, InvalidInput, MissingOuterHit, NoMaterialSegment
};
struct BoundaryHit {
    Vec2 point;
    double distance = 0.0; // along the directed finite chord
    LoopKind kind = LoopKind::Outer;
    std::size_t loop_index = 0; // source loop ID, 0 is outer
    std::size_t edge_index = 0; // edge in normalized loop
    double edge_fraction = 0.0;
    bool existing_vertex = false;
    bool collinear = false;
};
struct MaterialInterval {
    Vec2 first;
    Vec2 last;
    double from = 0.0;
    double to = 0.0;
};
// The outer endpoints are merely the planned chord. Only intervals in
// the actual face domain become Cut edges (holes are never filled).
struct SplitTrace {
    Vec2 first;
    Vec2 last;
    std::vector<BoundaryHit> intersections;
    std::vector<MaterialInterval> material_intervals;
    std::size_t inspected_holes = 0;
};
struct TraceResult {
    std::optional<SplitTrace> trace;
    TraceError error = TraceError::None;
};
Location classify_loop(const std::vector<Vec2>& ring, Vec2 point, double tolerance);
Location classify_domain(const NormalizedFace& face, Vec2 point, double tolerance);
TraceResult trace_split(
    const NormalizedFace& face,
    const SplitCandidate& candidate,
    double tolerance
);
} // namespace IndoorGMLAdjacencyNative::FloorPartition
