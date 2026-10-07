#pragma once

#include "adjacency_data.h"

#include <optional>

namespace IndoorGMLAdjacencyNative
{
struct StateSearchMetrics
{
    bool volume_centroid_succeeded = false;
    bool used_bvh = false;
    double bvh_build_duration = 0.0;
    double bvh_search_duration = 0.0;
};

std::optional<Vec3> find_state_point(
    const CellData& cell,
    double tolerance,
    StateSearchMetrics* metrics = nullptr
);
} // namespace IndoorGMLAdjacencyNative
