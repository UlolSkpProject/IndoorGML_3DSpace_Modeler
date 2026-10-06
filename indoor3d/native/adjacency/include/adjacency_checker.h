#pragma once

#include "adjacency_data.h"

#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
bool bounds_overlap(const Aabb& first, const Aabb& second, double tolerance);

std::vector<PairIndex> z_sweep_candidates(
    const std::vector<CellData>& cells,
    double tolerance
);

std::optional<PairResult> analyze_pair(
    const CellData& first,
    const CellData& second,
    double length_tolerance,
    double normal_tolerance
);
} // namespace IndoorGMLAdjacencyNative
