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

struct CellSpaceInteriorPointResult
{
    std::optional<Vec3> state_point;
    std::vector<Vec3> reference_points;
    StateSearchMetrics state_metrics;
    ReferencePointStatus reference_status = ReferencePointStatus::NotAttempted;
};

std::optional<Vec3> find_state_point(
    const CellData& cell,
    double tolerance,
    StateSearchMetrics* metrics = nullptr
);

std::vector<Vec3> find_reference_points(
    const CellData& cell,
    const Vec3& state_point,
    double tolerance
);

CellSpaceInteriorPointResult locate_cell_space_interior_points(
    const CellData& cell,
    double tolerance
);
} // namespace IndoorGMLAdjacencyNative
