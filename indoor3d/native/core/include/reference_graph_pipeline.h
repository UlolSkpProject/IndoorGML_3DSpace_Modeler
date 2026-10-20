#pragma once

#include "cell_space_interior_point_locator.h"
#include "floor_face_solid.h"

#include <array>
#include <cstddef>
#include <limits>
#include <memory>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
enum class ReferenceGraphStage
{
    Before,
    After,
    Collapsed,
    Optimized,
    LosGraph, // All unobstructed pairs from OPTIMIZED nodes, ignoring its edges.
    ShortPathGraph // Derived, read-only view of the State-rooted Dijkstra tree.
};

struct ReferenceGraphStageSnapshot
{
    std::vector<ReferenceGraphNode> nodes;
    std::vector<ReferenceGraphEdge> edges;
    std::vector<std::optional<std::size_t>> original_indices;
    std::vector<bool> protected_nodes;
};

struct ReferenceGraphShortestPathTree
{
    std::size_t root = 0;
    std::vector<double> distances;
    std::vector<std::optional<std::size_t>> previous;
};

struct ReferenceGraphPipeline
{
    ReferenceGraphStageSnapshot before;
    ReferenceGraphStageSnapshot after;
    ReferenceGraphStageSnapshot collapsed;
    ReferenceGraphStageSnapshot optimized;
    ReferenceGraphStageSnapshot los_graph;
    std::size_t state_node_index = 0;
    std::size_t optimized_bridge_count = 0;
    std::size_t unreachable_node_count = 0;
    ReferenceGraphShortestPathTree shortest_path_tree;
    // Reusable Solid queries for waypoint routing after the geometry batch is cleared.
    std::shared_ptr<const FaceSolid> waypoint_solid;
    double waypoint_tolerance = 0.001;
    // Preserve the pre-existing State-only route if legacy fallback has no valid Solid.
    bool legacy_state_only = false;
};

// OPTIMIZED reductions remain available for debugging. Routing uses an
// independent Full LOS graph formed from OPTIMIZED nodes, then a State-rooted
// shortest-path tree. Radius never appears in the public Ruby snapshots.
ReferenceGraphPipeline build_reference_graph_pipeline(
    const CellData& cell,
    const ReferenceGraphDebug& before,
    double tolerance
);

// A CellSpace recovered by legacy fallback uses its State itself as a one-node
// reference graph. This keeps transition routing uniform without inventing
// modern reference points after the category-aware policy failed.
ReferenceGraphPipeline build_state_reference_graph_pipeline(
    const Vec3& state_point,
    const CellData& cell,
    double tolerance
);

const ReferenceGraphStageSnapshot& reference_graph_stage(
    const ReferenceGraphPipeline& pipeline,
    ReferenceGraphStage stage
);

// Display-only snapshot: LOS_GRAPH nodes with only the State-rooted shortest-
// path predecessor edges. Disconnected nodes remain as isolated markers.
// Reuses the already baked tree; never recomputes graph topology or routes.
ReferenceGraphStageSnapshot reference_short_path_graph(
    const ReferenceGraphPipeline& pipeline
);

// Finalize every persistent stage and LOS Solid in the post-State CellSpace
// Local frame. root_to_local is a rigid SketchUp column-major 4x4 transform.
void finalize_reference_graph_local(
    ReferenceGraphPipeline& pipeline,
    const CellData& root_cell,
    const std::array<double,16>& root_to_local
);

// Closest LOS_GRAPH node that remains reachable from State. The raw shared
// Face centroid is used as the query before waypoint Z is adjusted.
std::optional<Vec3> closest_reachable_reference_point(
    const ReferenceGraphPipeline& pipeline,
    const Vec3& waypoint
);

// Returns State -> the LOS-visible gateway minimizing
// (State-to-gateway shortest-path length + gateway-to-waypoint distance)
// -> waypoint. The SPT is baked once when the CellSpace graph is rebuilt.
std::vector<Vec3> reference_transition_polyline(
    const ReferenceGraphPipeline& pipeline,
    const Vec3& waypoint
);
} // namespace IndoorGMLAdjacencyNative
