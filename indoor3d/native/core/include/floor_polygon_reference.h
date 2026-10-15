#pragma once
#include "floor_polygon_queue.h"

#include <cstddef>
#include <vector>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
enum class SeedKind { PolygonCentroid, SharedEdgeMidpoint };
struct Seed {
    Vec3 position;
    SeedKind kind=SeedKind::PolygonCentroid;
    std::size_t first_leaf=0;
    std::size_t second_leaf=NO_EDGE;
};
struct ReferenceSeeds {
    std::vector<Seed> points;
    std::size_t rejected_centroids=0;
    std::size_t shared_segments=0;
    std::size_t limit_reached=0;
};
struct ReferenceOptions {
    // SketchUp core uses inches; existing Room/Stair anchors rise 1000mm
    // along world Z, not along an inclined floor normal.
    double world_z_offset=1000.0/25.4;
    std::size_t max_points=4096;
};
ReferenceSeeds generate_reference_seeds(
    const std::vector<PartitionLeaf>& completed,
    double tolerance,
    ReferenceOptions options={});
} // namespace IndoorGMLAdjacencyNative::FloorPartition
