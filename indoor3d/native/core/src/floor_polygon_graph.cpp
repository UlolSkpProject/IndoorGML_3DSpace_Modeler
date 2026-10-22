#include "floor_polygon_graph.h"
#include <algorithm>
#include <cmath>
#include <utility>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
namespace
{
Vec2 sub(Vec2 a,Vec2 b) { return {a.x-b.x,a.y-b.y}; }
Vec2 add(Vec2 a,Vec2 b) { return {a.x+b.x,a.y+b.y}; }
Vec2 mul(Vec2 p,double t) { return {p.x*t,p.y*t}; }
double dot(Vec2 a,Vec2 b) { return a.x*b.x+a.y*b.y; }
double distance(Vec2 a,Vec2 b) { return std::hypot(a.x-b.x,a.y-b.y); }

std::size_t vertex_id(PlanarGraph& graph,Vec2 point,double tolerance)
{
    // In Phase 4 topology is small enough that a linear lookup is safer
    // than a quantized hash that may incorrectly merge narrow corridors.
    for (std::size_t i=0;i<graph.vertices.size();++i)
        if (distance(point,graph.vertices[i].position)<=tolerance)
            return i;
    graph.vertices.push_back({point});
    return graph.vertices.size()-1;
}

bool add_edge(PlanarGraph& graph,std::size_t a,std::size_t b,
              EdgeKind kind,std::size_t loop,std::size_t source)
{
    if (a==b) return false;
    for (const GraphEdge& e:graph.edges)
        if ((e.first==a&&e.second==b) ||
            (e.first==b&&e.second==a))
        {
            // The trace merely overlaps a source boundary: keep the
            // original edge and do NOT create a second/twin Cut edge.
            return false;
        }
    const std::size_t index=graph.edges.size();
    const std::size_t twin=graph.half_edges.size();
    graph.edges.push_back({a,b,kind,loop,source});
    graph.half_edges.push_back({a,b,twin+1,NO_EDGE,NO_EDGE,index});
    graph.half_edges.push_back({b,a,twin,NO_EDGE,NO_EDGE,index});
    if (kind==EdgeKind::Cut) ++graph.cut_edges;
    return true;
}

bool append_boundary(
    PlanarGraph& graph,const NormalizedLoop& loop,
    const SplitTrace& trace,double tolerance)
{
    for (std::size_t i=0;i<loop.points.size();++i)
    {
        const Vec2 a=loop.points[i],b=loop.points[(i+1)%loop.points.size()];
        const Vec2 delta=sub(b,a);
        const double square=dot(delta,delta);
        if (square<=tolerance*tolerance) return false;
        std::vector<std::pair<double,Vec2>> ordered{{0.0,a},{1.0,b}};
        for (const BoundaryHit& hit:trace.intersections)
        {
            if (hit.loop_index!=loop.source_loop_index ||
                hit.edge_index!=i) continue;
            const double projection=std::clamp(
                dot(sub(hit.point,a),delta)/square,0.0,1.0);
            ordered.push_back({projection,
                add(a,mul(delta,projection))});
        }
        std::sort(ordered.begin(),ordered.end(),
            [](const auto& x,const auto& y) { return x.first<y.first; });
        std::size_t previous=vertex_id(graph,a,tolerance);
        for (std::size_t j=1;j<ordered.size();++j)
        {
            const std::size_t next=vertex_id(
                graph,ordered[j].second,tolerance);
            if (previous!=next)
            {
                // A zero-length input Edge is invalid, but two nearby
                // intersections on one edge may legitimately collapse.
                add_edge(graph,previous,next,
                    loop.hole?EdgeKind::InnerBoundary:EdgeKind::OuterBoundary,
                    loop.source_loop_index,i);
                previous=next;
            }
        }
    }
    return true;
}
} // namespace

GraphResult build_graph(const NormalizedFace& face,
                        const SplitTrace& trace,double tolerance)
{
    if (!std::isfinite(tolerance)||tolerance<=0.0 ||
        face.outer.points.size()<3)
        return {{},GraphError::InvalidInput};
    PlanarGraph graph;
    if (!append_boundary(graph,face.outer,trace,tolerance))
        return {{},GraphError::DegenerateSourceEdge};
    for (const NormalizedLoop& hole:face.holes)
        if (!append_boundary(graph,hole,trace,tolerance))
            return {{},GraphError::DegenerateSourceEdge};

    for (const MaterialInterval& segment:trace.material_intervals)
    {
        if (distance(segment.first,segment.last)<=tolerance) continue;
        const std::size_t first=vertex_id(graph,segment.first,tolerance);
        const std::size_t last=vertex_id(graph,segment.last,tolerance);
        add_edge(graph,first,last,EdgeKind::Cut,0,0);
    }
    if (graph.cut_edges==0) return {{},GraphError::NoInteriorCut};
    return {std::move(graph),GraphError::None};
}
} // namespace IndoorGMLAdjacencyNative::FloorPartition
