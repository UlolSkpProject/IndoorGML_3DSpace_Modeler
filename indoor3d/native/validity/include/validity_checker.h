#pragma once

#include "validity_data.h"

#include <manifold/manifold.h>

namespace IndoorGMLValidityNative
{
ValidityResult check_overlap_701(
    const manifold::Manifold& first,
    const manifold::Manifold& second,
    double thickness_tolerance
);

ValidityResult check_adjacency_704(
    const IndoorGMLAdjacencyNative::CellData& first,
    const IndoorGMLAdjacencyNative::CellData& second,
    double length_tolerance,
    double normal_tolerance
);
} // namespace IndoorGMLValidityNative
