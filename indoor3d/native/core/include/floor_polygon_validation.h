#pragma once
#include "floor_polygon_regions.h"

#include <cstddef>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
// Phase 7: a partition is COMMITTED only after the complete set of
// positive-area children preserves the parent's exact domain.
// Failures leave the input NormalizedFace and source geometry untouched.
struct SharedBoundary {
    std::size_t edge_id=NO_EDGE;
    std::size_t first_region=NO_EDGE;
    std::size_t second_region=NO_EDGE;
    Vec2 first;
    Vec2 last;
};
struct ValidatedPartition {
    std::vector<PartitionRegion> children;
    std::vector<SharedBoundary> shared_cuts;
    double original_area=0.0;
};
enum class ValidationError {
    None, InvalidInput, NoSplit, AreaTooSmall, AreaNotConserved,
    InvalidBoundary, InvalidOwnership, CutNotShared, RegionOverlap,
    HoleNotPreserved, TooManyEdges
};
struct ValidationResult {
    std::optional<ValidatedPartition> partition;
    ValidationError error=ValidationError::None;
};
ValidationResult validate_partition(const NormalizedFace& source,
                                    const CycleWalk& walk,
                                    const RegionExtraction& regions,
                                    double tolerance);

// Phase 8 will orchestrate a Queue of these independent, transactional
// attempts. Keep a typed stage/error diagnostic now for failed candidates.
enum class AttemptStage {
    None, Intersections, Graph, Cycles, Regions, Validation
};
struct PartitionAttempt {
    std::optional<ValidatedPartition> partition;
    AttemptStage failed_stage=AttemptStage::None;
    TraceError trace_error=TraceError::None;
    GraphError graph_error=GraphError::None;
    CycleError cycle_error=CycleError::None;
    RegionError region_error=RegionError::None;
    ValidationError validation_error=ValidationError::None;
};
PartitionAttempt attempt_partition(const NormalizedFace& source,
                                   const SplitCandidate& candidate,
                                   double tolerance);
} // namespace IndoorGMLAdjacencyNative::FloorPartition
