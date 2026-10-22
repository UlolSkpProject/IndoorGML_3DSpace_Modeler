#pragma once

#include "adjacency_data.h"
#include "state_exit_code.h"

#include <array>
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
struct StateSearchMetrics
{
    bool volume_centroid_succeeded = false;
    bool used_bvh = false;
    double bvh_build_duration = 0.0;
    double bvh_search_duration = 0.0;
};

enum class ReferencePointStatus : std::uint64_t
{
    NotAttempted = 0,
    Succeeded = 1,
    Failed = 2
};

enum class ReferencePointKind : std::uint64_t
{
    Face = 1,
    Corner = 2,
    Merged = 3,
    Final = 4
};

struct ReferencePoint
{
    Vec3 point;
    ReferencePointKind kind = ReferencePointKind::Face;
};

// Signed exterior-turn accumulation for Room wall chains.
// Reflex: negative, convex: positive, straight/parallel: zero.
// Preserve a negative run across positive offsets, reset only once the
// signed sum reaches zero. Emit only on a negative turn at -threshold.
class RoomSignedTurnAccumulator
{
public:
    explicit RoomSignedTurnAccumulator(double threshold_degrees)
        : threshold_degrees_(threshold_degrees) {}

    bool advance(double signed_turn_degrees)
    {
        accumulated_degrees_ += signed_turn_degrees;
        if (accumulated_degrees_ >= 0.0)
        {
            accumulated_degrees_ = 0.0;
            return false;
        }
        if (signed_turn_degrees < 0.0 &&
            accumulated_degrees_ <= -threshold_degrees_ + 1.0e-9)
        {
            accumulated_degrees_ = 0.0;
            return true;
        }
        return false;
    }

    double accumulated_degrees() const { return accumulated_degrees_; }

private:
    double threshold_degrees_;
    double accumulated_degrees_ = 0.0;
};

struct ReferenceGraphNode
{
    Vec3 point;
    double radius = 0.0;
};

struct ReferenceGraphEdge
{
    std::size_t first = 0;
    std::size_t second = 0;
};

struct ReferenceLoopCollapseCandidate
{
    // Ordered vertex indices of a simple induced 3+ cycle in the ORIGINAL graph.
    std::vector<std::size_t> vertices;
    ReferenceGraphNode representative;
    // Geometry-validated candidates for new edges to original nodes.
    std::vector<std::size_t> visible_neighbors;
};

struct ReferenceFloorPartition
{
    // Exact completed PartitionLeaf boundaries, lifted back into the
    // SketchUp parent coordinate system. Rings are not explicitly closed.
    std::vector<Vec3> outer;
    std::vector<std::vector<Vec3>> holes;
};

struct ReferenceGraphDebug
{
    // Native-only BEFORE graph. Later stages keep their own snapshots in the
    // keyed Reference repository and never expose radius to Ruby.
    std::vector<ReferenceGraphNode> nodes;
    std::vector<ReferenceGraphEdge> edges;
    std::vector<ReferenceLoopCollapseCandidate> loop_candidates;
    std::vector<ReferenceFloorPartition> floor_partitions;
    // Actual BEFORE index of the validated reference seed with the greatest
    // horizontal wall clearance (Polygon centroid or shared-edge midpoint).
    // Radius ties use AABB-center distance, then stable seed order. The
    // selected anchor must survive every later graph reduction.
    std::optional<std::size_t> state_node_index;
};

struct CellSpaceInteriorPointResult
{
    std::optional<Vec3> state_point;
    StateExitCode exit_code=StateExitCode::LegacyNoState;
    StateDiagnostics diagnostics;
    std::vector<ReferencePoint> reference_points;
    ReferenceGraphDebug debug_graph;
    StateSearchMetrics state_metrics;
    ReferencePointStatus reference_status = ReferencePointStatus::NotAttempted;
    // True only when the category-aware Floor reference policy produced no
    // valid point and the legacy volumetric State search recovered this cell.
    bool used_legacy_fallback = false;
};

std::optional<Vec3> find_state_point(
    const CellData& cell,
    double tolerance,
    StateSearchMetrics* metrics = nullptr
);

// Legacy triangle-backed debug helper for Floor reference seeds. Runtime
// State generation uses locate_reference_before below.
// Seeds are the area centroid of EVERY
// final Floor polygon plus the midpoint of each straight boundary shared
// by TWO distinct final polygons (never triangulation-internal edges).
// Uses +1000mm world-Z placement and retains the Solid BVH safety checks.
std::vector<ReferencePoint> find_reference_points(
    const CellData& cell,
    double tolerance
);

// Non-mutating BEFORE visibility graph for Room and Stair. No final Floor
// polygons or original SketchUp entities are modified here.
ReferenceGraphDebug build_room_reference_visibility_graph(
    const CellData& cell,
    const std::vector<ReferencePoint>& reference_points,
    double tolerance
);

// Category-aware 3D Solid-boundary LOS verification for any point elevations.
// Uses BVH segment/triangle crossings, not horizontal wall slices.
std::vector<bool> validate_room_reference_segments(
    const CellData& cell,
    const std::vector<std::pair<Vec3, Vec3>>& segments,
    double tolerance
);

// Room/Stair/Door/Elevator/Window reference preparation and BEFORE graph.
// State is the validated centroid or shared-edge seed with the greatest
// horizontal wall clearance. Radius ties prefer the CellSpace AABB center.
// locate_cell_space_interior_points applies legacy fallback only when this
// category-aware path yields no valid reference.
CellSpaceInteriorPointResult locate_reference_before(
    const CellData& cell,
    double tolerance
);

CellSpaceInteriorPointResult locate_cell_space_interior_points(
    const CellData& cell,
    double tolerance
);
} // namespace IndoorGMLAdjacencyNative
