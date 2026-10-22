#pragma once

#include <cstdint>

namespace IndoorGMLAdjacencyNative
{
// Stable per-Cell exit codes (int). 0 means a valid State was selected.
// Native exceptions and wire/protocol errors are NOT normal ExitCodes.
enum class StateExitCode : std::uint32_t
{
    Success                  = 0,
    InvalidInput             = 10,
    InvalidSolidGeometry     = 20,
    NoFloorFaces             = 30,
    FloorPreparationFailed   = 31,
    PartitionFailed          = 40,
    PartitionLimitReached    = 41,
    NoReferenceCandidates    = 50,
    InvalidCentroids         = 51,
    OutsideSolid             = 60,
    InsufficientClearance    = 61,
    MixedReferenceRejections = 62,
    LegacyNoState            = 90
};

// Aggregate diagnostics retain partial-failure information even when
// exit_code=0: one bad Face must NOT invalidate valid references elsewhere.
struct StateDiagnostics
{
    std::uint64_t floor_faces=0;
    std::uint64_t prepared_faces=0;
    std::uint64_t completed_polygons=0;
    std::uint64_t failed_polygons=0;
    std::uint64_t reference_candidates=0;
    std::uint64_t rejected_centroids=0;
    std::uint64_t rejected_outside=0;
    std::uint64_t rejected_clearance=0;
    std::uint64_t accepted_references=0;
};
} // namespace IndoorGMLAdjacencyNative
