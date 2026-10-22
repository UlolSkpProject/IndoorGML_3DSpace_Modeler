#pragma once
#include "floor_polygon_queue.h"

#include <cstddef>
#include <functional>
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
    // SketchUp core uses inches; standard navigable anchors rise 1000mm
    // along world Z, not along an inclined floor normal.
    double world_z_offset=1000.0/25.4;
    std::size_t max_points=4096;
};
struct CoarsenedPartitions {
    std::vector<PartitionLeaf> leaves;
    // Input leaf indices represented by each output leaf. This lets the
    // runtime validate a merged centroid against the seeds it replaces.
    std::vector<std::vector<std::size_t>> source_leaf_indices;
    std::size_t accepted_merges=0;
};
// The callback receives the proposed convex union and its input-leaf indices.
// It can reject a pair before the geometry-only coarsener commits that pair.
using MergeAcceptance = std::function<bool(
    const PartitionLeaf&, const std::vector<std::size_t>&)>;
// Deterministic, non-destructive convex coarsening of coplanar Floor leaves,
// including leaves from DIFFERENT original SketchUp Faces. Face identity
// never substitutes for shared boundary, hole-free union or area checks.
CoarsenedPartitions merge_convex_partitions(
    const std::vector<PartitionLeaf>& completed,
    double tolerance,
    const MergeAcceptance& accept={});
// Preserve previously safe maximal merges. If a maximal union fails the
// callback, recover verified smaller convex unions and repeatedly revisit
// the entire surviving set. The callback always receives ORIGINAL leaf
// indices, including for unions across previously separate source Faces.
std::vector<PartitionLeaf> coarsen_with_safe_fallback(
    const std::vector<PartitionLeaf>& completed,
    double tolerance,
    const MergeAcceptance& accept);
ReferenceSeeds generate_reference_seeds(
    const std::vector<PartitionLeaf>& completed,
    double tolerance,
    ReferenceOptions options={});
} // namespace IndoorGMLAdjacencyNative::FloorPartition
