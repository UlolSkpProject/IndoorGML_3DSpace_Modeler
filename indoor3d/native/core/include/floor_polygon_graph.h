#pragma once
#include "floor_polygon_intersections.h"

#include <cstddef>
#include <limits>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
// Phase 4: build a temporary planar graph. Source loops are never edited.
constexpr std::size_t NO_EDGE = std::numeric_limits<std::size_t>::max();
enum class EdgeKind { OuterBoundary, InnerBoundary, Cut };
struct GraphVertex { Vec2 position; };
struct GraphEdge {
    std::size_t first=0;
    std::size_t second=0;
    EdgeKind kind=EdgeKind::OuterBoundary;
    std::size_t source_loop_index=0;
    std::size_t source_edge_index=0;
};
struct GraphHalfEdge {
    std::size_t origin=0;
    std::size_t destination=0;
    std::size_t twin=NO_EDGE;
    std::size_t next=NO_EDGE;
    std::size_t prev=NO_EDGE;
    std::size_t edge_id=0;
};
struct PlanarGraph {
    std::vector<GraphVertex> vertices;
    std::vector<GraphEdge> edges;
    std::vector<GraphHalfEdge> half_edges;
    std::size_t cut_edges=0;
};
enum class GraphError {
    None, InvalidInput, NoInteriorCut, DegenerateSourceEdge
};
struct GraphResult {
    std::optional<PlanarGraph> graph;
    GraphError error=GraphError::None;
};
GraphResult build_graph(const NormalizedFace& face,
                        const SplitTrace& trace,double tolerance);
} // namespace IndoorGMLAdjacencyNative::FloorPartition
