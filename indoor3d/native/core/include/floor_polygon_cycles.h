#pragma once
#include "floor_polygon_graph.h"

#include <cstddef>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
// Phase 5: assign DCEL next/prev around each vertex and walk the
// bounded left-hand boundary of every directed halfedge.
struct BoundaryCycle {
    std::vector<std::size_t> halfedge_ids;
    std::vector<std::size_t> vertex_ids;
    double signed_area=0.0;
    bool material_on_left=false;
};
enum class CycleError {
    None, InvalidGraph, DanglingHalfedge, OpenWalk
};
struct CycleWalk {
    PlanarGraph graph;
    std::vector<BoundaryCycle> cycles; // also includes exterior/void cycles
    std::vector<std::size_t> cycle_of_halfedge;
};
struct CycleResult {
    std::optional<CycleWalk> walk;
    CycleError error=CycleError::None;
};
CycleResult walk_cycles(PlanarGraph graph,
                        const NormalizedFace& source,double tolerance);
} // namespace IndoorGMLAdjacencyNative::FloorPartition
