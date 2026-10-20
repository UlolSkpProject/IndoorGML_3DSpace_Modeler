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
// TEMPORARY TEST SWITCH. True: OPTIMIZED (validated existing edges) -> REPAIR.
// False: OPTIMIZED -> FULL LOS -> REPAIR (normal stage ordering).
// This is deliberately compile-time so the original path is preserved.
inline constexpr bool SKIP_PRE_REPAIR_FULL_LOS_FOR_TEST = true;

enum class ReferenceGraphStage
{
    Before,
    Collapsed,
    Optimized,
    LosGraph, // Full LOS or validated sparse OPTIMIZED input (temporary test mode).
    ConnectivityRepair, // LOS graph augmented with proven intermediate references.
    ShortPathGraph // Derived, read-only view of the State-rooted Dijkstra tree.
};

// Node identity/provenance, not a blanket protection flag. In particular,
// LoopCollapseCandidate vertices and visible_neighbors are certificates only.
enum class ReferenceNodeRole
{
    Reference,
    State,
    CollapseRepresentative,
    RecoveredReference
};

// Protection belongs to the operation, not the lifetime of every reference.
// State is immutable; a collapse representative remains fixed through
// OPTIMIZED until all LOS edges are independently rebuilt.
inline bool reference_node_protected_from_optimization(ReferenceNodeRole role)
{
    return role == ReferenceNodeRole::State ||
           role == ReferenceNodeRole::CollapseRepresentative;
}

struct ReferenceGraphStageSnapshot
{
    std::vector<ReferenceGraphNode> nodes;
    std::vector<ReferenceGraphEdge> edges;
    std::vector<std::optional<std::size_t>> original_indices;
    // Aligned with nodes. The role survives Stage snapshots and remapping.
    std::vector<ReferenceNodeRole> node_roles;
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
    ReferenceGraphStageSnapshot collapsed;
    ReferenceGraphStageSnapshot optimized;
    ReferenceGraphStageSnapshot los_graph;
    ReferenceGraphStageSnapshot repaired_graph;
    std::size_t state_node_index = 0;
    std::size_t recovered_node_count = 0; // Additional proven interior references.
    std::size_t unreachable_node_count = 0; // Unreachable in repaired graph's State tree.
    ReferenceGraphShortestPathTree shortest_path_tree;
    // Reusable Solid queries for waypoint routing after the geometry batch is cleared.
    std::shared_ptr<const FaceSolid> waypoint_solid;
    double waypoint_tolerance = 0.001;
    // Preserve the pre-existing State-only route if legacy fallback has no valid Solid.
    bool legacy_state_only = false;
};

// BEFORE -> COLLAPSED -> OPTIMIZED -> optional FULL LOS ->
// CONNECTIVITY_REPAIR -> State-rooted Dijkstra. The temporary test switch
// omits all-pairs LOS before Repair while keeping individual Edge checks.
// Radius is not exposed in Ruby snapshots.
ReferenceGraphPipeline build_reference_graph_pipeline(
    const CellData& cell,
    const ReferenceGraphDebug& before,
    double tolerance
);

// Restore discarded references only when they form genuine LOS paths between
// disconnected State and target components. Never add an unvalidated Edge.
struct ReferenceConnectivityRepairResult
{
    ReferenceGraphStageSnapshot graph;
    std::size_t added_nodes=0;
};
ReferenceConnectivityRepairResult repair_reference_connectivity(
    const ReferenceGraphStageSnapshot& los_graph,
    const ReferenceGraphStageSnapshot& before,
    const ReferenceGraphStageSnapshot& collapsed,
    std::size_t state_node_index,const FaceSolid& solid,double tolerance
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

// Display-only snapshot: repaired graph nodes with only the State-rooted shortest-
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

// Closest final repaired-graph node that remains reachable from State. The raw shared
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
