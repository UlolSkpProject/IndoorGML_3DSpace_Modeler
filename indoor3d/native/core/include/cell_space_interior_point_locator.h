#pragma once

#include "adjacency_data.h"

#include <cstdint>
#include <optional>
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

struct ReferenceGraphDebug
{
    // Node zero is always State; all other nodes are Final references.
    std::vector<ReferenceGraphNode> nodes;
    std::vector<ReferenceGraphEdge> edges;
};

struct CellSpaceInteriorPointResult
{
    std::optional<Vec3> state_point;
    std::vector<ReferencePoint> reference_points;
    ReferenceGraphDebug debug_graph;
    StateSearchMetrics state_metrics;
    ReferencePointStatus reference_status = ReferencePointStatus::NotAttempted;
};

std::optional<Vec3> find_state_point(
    const CellData& cell,
    double tolerance,
    StateSearchMetrics* metrics = nullptr
);

std::vector<ReferencePoint> find_reference_points(
    const CellData& cell,
    const Vec3& state_point,
    double tolerance
);

// Room-only, non-mutating diagnostic graph. No references are merged here.
ReferenceGraphDebug build_room_reference_visibility_graph(
    const CellData& cell,
    const Vec3& state_point,
    const std::vector<ReferencePoint>& reference_points,
    double tolerance
);

CellSpaceInteriorPointResult locate_cell_space_interior_points(
    const CellData& cell,
    double tolerance
);
} // namespace IndoorGMLAdjacencyNative
