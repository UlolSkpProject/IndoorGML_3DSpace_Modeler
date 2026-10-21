#pragma once
#include "floor_polygon_validation.h"

#include <cstddef>
#include <vector>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
// Phase 8. Only valid children are enqueued. Failed polygons are
// retained for diagnostics and failure recovery, never silently discarded.
struct PartitionFailure {
    std::size_t source_face_id=0;
    std::size_t depth=0;
    NormalizedFace polygon;
    std::vector<PartitionAttempt> rejected_candidates;
    bool limit_exceeded=false;
    bool invalid_child=false;
};
struct PartitionLeaf {
    // Original Floor Face ID on input; after cross-Face coarsening this is
    // the minimum member Face ID. Full membership remains in
    // CoarsenedPartitions::source_leaf_indices (while merging).
    std::size_t source_face_id=0;
    std::size_t depth=0;
    NormalizedFace polygon;
};
struct PartitionBatch {
    std::vector<PartitionLeaf> completed;
    std::vector<PartitionFailure> failed;
    std::size_t accepted_splits=0;
    std::size_t attempted_splits=0;
};
struct QueueLimits {
    std::size_t max_splits=4096;
    std::size_t max_depth=64;
    std::size_t max_candidates_per_face=128;
};
PartitionBatch partition_queue(const NormalizedFace& source,
                               std::size_t source_face_id,
                               double tolerance,
                               QueueLimits limits = {});
} // namespace IndoorGMLAdjacencyNative::FloorPartition
