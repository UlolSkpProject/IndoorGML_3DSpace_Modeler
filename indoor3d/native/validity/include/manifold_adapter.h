#pragma once

#include "geometry_data.h"

#include <manifold/manifold.h>

#include <memory>

namespace IndoorGMLValidityNative
{
std::shared_ptr<manifold::Manifold> build_manifold(
    const IndoorGMLAdjacencyNative::CellData& cell
);
} // namespace IndoorGMLValidityNative
