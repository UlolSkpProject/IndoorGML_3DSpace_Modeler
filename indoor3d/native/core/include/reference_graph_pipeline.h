#pragma once

#include "cell_space_interior_point_locator.h"
#include "floor_face_solid.h"

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
    Optimized
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

// All radius-dependent reductions, LOS-safe OPTIMIZED component bridges and
// shortest-path preprocessing are Native. Radius never appears in the public
// Ruby snapshots returned by native_api.
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

// Closest OPTIMIZED node that remains reachable from State. The raw shared
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
