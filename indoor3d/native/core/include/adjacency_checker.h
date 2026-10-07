#pragma once

#include "exact_face_adjacency.h"

#include <vector>

namespace IndoorGMLAdjacencyNative
{
std::vector<PairIndex> z_sweep_candidates(
    const std::vector<CellData>& cells,
    double tolerance
);
} // namespace IndoorGMLAdjacencyNative
