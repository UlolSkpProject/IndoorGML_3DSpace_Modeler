#pragma once

#include "geometry_data.h"

#include <optional>

namespace IndoorGMLAdjacencyNative
{
bool bounds_overlap(const Aabb& first, const Aabb& second, double tolerance);

std::optional<PairResult> analyze_pair(
    const CellData& first,
    const CellData& second,
    double length_tolerance,
    double normal_tolerance
);
} // namespace IndoorGMLAdjacencyNative
