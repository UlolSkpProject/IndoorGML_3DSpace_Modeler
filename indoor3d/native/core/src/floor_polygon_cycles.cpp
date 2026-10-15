#include "floor_polygon_cycles.h"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
namespace
{
Vec2 sub(Vec2 a,Vec2 b) { return {a.x-b.x,a.y-b.y}; }
Vec2 add(Vec2 a,Vec2 b) { return {a.x+b.x,a.y+b.y}; }
Vec2 mul(Vec2 a,double t) { return {a.x*t,a.y*t}; }
double cross(Vec2 a,Vec2 b) { return a.x*b.y-a.y*b.x; }
double length(Vec2 a) { return std::hypot(a.x,a.y); }

double cycle_area(const BoundaryCycle& cycle,const PlanarGraph& graph)
{
    if (cycle.vertex_ids.size()<3) return 0.0;
    const Vec2 anchor=graph.vertices[cycle.vertex_ids[0]].position;
    double twice=0.0;
    for (std::size_t i=0;i<cycle.vertex_ids.size();++i)
    {
        const Vec2 a=sub(graph.vertices[cycle.vertex_ids[i]].position,anchor);
        const Vec2 b=sub(graph.vertices[
            cycle.vertex_ids[(i+1)%cycle.vertex_ids.size()]].position,anchor);
        twice+=cross(a,b);
    }
    return 0.5*twice;
}

bool left_is_material(const BoundaryCycle& cycle,const PlanarGraph& graph,
                      const NormalizedFace& source,double tolerance)
{
    for (std::size_t h:cycle.halfedge_ids)
    {
        const GraphHalfEdge& e=graph.half_edges[h];
        const Vec2 a=graph.vertices[e.origin].position;
        const Vec2 b=graph.vertices[e.destination].position;
        const Vec2 delta=sub(b,a);
        const double d=length(delta);
        if (d<=tolerance*2.0) continue;
        const Vec2 left={-delta.y/d,delta.x/d};
        const Vec2 midpoint=mul(add(a,b),0.5);
        // Must stand beyond boundary tolerance yet remain local. Narrow
        // / ambiguous material classification is handled fail-closed.
        for (double scale:{2.0,4.0,8.0})
        {
            const double offset=std::min(scale*tolerance,d*0.2);
            const Vec2 p=add(midpoint,mul(left,offset));
            const Location where=classify_domain(source,p,tolerance);
            if (where==Location::Inside) return true;
            if (where==Location::Outside) return false;
        }
    }
    return false;
}
} // namespace

CycleResult walk_cycles(PlanarGraph graph,
                        const NormalizedFace& source,double tolerance)
{
    const std::size_t count=graph.half_edges.size();
    if (!std::isfinite(tolerance)||tolerance<=0 ||
        count==0 || count!=graph.edges.size()*2 ||
        graph.vertices.empty()) return {{},CycleError::InvalidGraph};

    std::vector<std::vector<std::size_t>> outgoing(graph.vertices.size());
    for (std::size_t i=0;i<count;++i)
    {
        const auto& edge=graph.half_edges[i];
        if (edge.origin>=graph.vertices.size() ||
            edge.destination>=graph.vertices.size() ||
            edge.twin>=count || edge.origin==edge.destination ||
            graph.half_edges[edge.twin].twin!=i ||
            graph.half_edges[edge.twin].origin!=edge.destination ||
            graph.half_edges[edge.twin].destination!=edge.origin)
            return {{},CycleError::InvalidGraph};
        outgoing[edge.origin].push_back(i);
    }
    for (std::size_t v=0;v<outgoing.size();++v)
    {
        auto& around=outgoing[v];
        std::sort(around.begin(),around.end(),
            [&](std::size_t a,std::size_t b) {
                const Vec2 origin=graph.vertices[v].position;
                const auto dest=[&](std::size_t id) {
                    return sub(graph.vertices[
                        graph.half_edges[id].destination].position,origin);
                };
                const Vec2 va=dest(a),vb=dest(b);
                const double aa=std::atan2(va.y,va.x);
                const double ab=std::atan2(vb.y,vb.x);
                return aa==ab?a<b:aa<ab;
            });
    }

    // Incoming edge a->b has material to its left. At b, turn to
    // the clockwise predecessor of its twin (b->a) in CCW ordering.
    for (std::size_t i=0;i<count;++i)
    {
        const auto& edge=graph.half_edges[i];
        const auto& around=outgoing[edge.destination];
        const auto it=std::find(around.begin(),around.end(),edge.twin);
        if (it==around.end()) return {{},CycleError::DanglingHalfedge};
        const std::size_t pos=static_cast<std::size_t>(it-around.begin());
        graph.half_edges[i].next=around[(pos+around.size()-1)%around.size()];
    }
    for (std::size_t i=0;i<count;++i)
    {
        const std::size_t next=graph.half_edges[i].next;
        if (next>=count || graph.half_edges[next].prev!=NO_EDGE)
            return {{},CycleError::InvalidGraph};
        graph.half_edges[next].prev=i;
    }

    CycleWalk walk;
    walk.graph=std::move(graph);
    walk.cycle_of_halfedge.assign(count,NO_EDGE);
    for (std::size_t seed=0;seed<count;++seed)
    {
        if (walk.cycle_of_halfedge[seed]!=NO_EDGE) continue;
        BoundaryCycle cycle;
        const std::size_t cycle_id=walk.cycles.size();
        std::size_t current=seed;
        for (std::size_t guard=0;guard<=count;++guard)
        {
            if (current>=count) return {{},CycleError::OpenWalk};
            if (walk.cycle_of_halfedge[current]!=NO_EDGE)
            {
                if (current!=seed) return {{},CycleError::OpenWalk};
                break;
            }
            walk.cycle_of_halfedge[current]=cycle_id;
            cycle.halfedge_ids.push_back(current);
            cycle.vertex_ids.push_back(walk.graph.half_edges[current].origin);
            current=walk.graph.half_edges[current].next;
        }
        if (current!=seed || cycle.vertex_ids.empty())
            return {{},CycleError::OpenWalk};
        cycle.signed_area=cycle_area(cycle,walk.graph);
        cycle.material_on_left=left_is_material(
            cycle,walk.graph,source,tolerance);
        walk.cycles.push_back(std::move(cycle));
    }
    return {std::move(walk),CycleError::None};
}
} // namespace IndoorGMLAdjacencyNative::FloorPartition
