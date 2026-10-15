#pragma once
#include "floor_polygon_cycles.h"

#include <cstddef>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
// Phase 6: a planar face can own multiple boundary cycles.
// Positive material cycles are new OUTERs; negative material cycles
// are INNERs assigned by strict geometric containment.
struct RegionLoop {
    std::vector<Vec2> points;
    std::vector<std::size_t> halfedge_ids;
    std::size_t cycle_id=NO_EDGE;
    double signed_area=0.0;
};
struct PartitionRegion {
    RegionLoop outer;
    std::vector<RegionLoop> holes;
    double net_area=0.0;
};
struct RegionExtraction {
    std::vector<PartitionRegion> regions;
    // For material cycles only. Exterior and hole void sides are NO_EDGE.
    std::vector<std::size_t> region_of_cycle;
};
enum class RegionError {
    None, NoOuterCycle, DegenerateBoundaryCycle, UnownedHole,
    TouchingOrAmbiguousHole
};
struct RegionResult {
    std::optional<RegionExtraction> extraction;
    RegionError error=RegionError::None;
};
RegionResult reconstruct_regions(const CycleWalk& walk,double tolerance);
} // namespace IndoorGMLAdjacencyNative::FloorPartition
