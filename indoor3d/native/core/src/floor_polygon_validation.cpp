#include "floor_polygon_validation.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <utility>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
namespace
{
Vec2 sub(Vec2 a,Vec2 b) { return {a.x-b.x,a.y-b.y}; }
Vec2 add(Vec2 a,Vec2 b) { return {a.x+b.x,a.y+b.y}; }
Vec2 mul(Vec2 a,double t) { return {a.x*t,a.y*t}; }
double dot(Vec2 a,Vec2 b) { return a.x*b.x+a.y*b.y; }
double cross(Vec2 a,Vec2 b) { return a.x*b.y-a.y*b.x; }
double length(Vec2 a) { return std::hypot(a.x,a.y); }
double distance(Vec2 a,Vec2 b) { return length(sub(a,b)); }

bool inside_region(const PartitionRegion& region,Vec2 p,double tolerance)
{
    if (classify_loop(region.outer.points,p,tolerance)!=Location::Inside)
        return false;
    for (const RegionLoop& hole:region.holes)
        if (classify_loop(hole.points,p,tolerance)!=Location::Outside)
            return false;
    return true;
}

// Find a point *strictly* inside a CCW Outer or CW Hole without
// assuming its area centroid lies inside a concave polygon.
std::optional<Vec2> ring_probe(const std::vector<Vec2>& ring,
                               bool clockwise,double tolerance)
{
    for (std::size_t i=0;i<ring.size();++i)
    {
        const Vec2 a=ring[i],b=ring[(i+1)%ring.size()];
        const Vec2 edge=sub(b,a);
        const double distance_edge=length(edge);
        if (distance_edge<=2*tolerance) continue;
        const Vec2 left={-edge.y/distance_edge,edge.x/distance_edge};
        const Vec2 normal=clockwise?mul(left,-1.0):left;
        for (double factor:{2.0,4.0,8.0})
        {
            const double offset=std::min(tolerance*factor,distance_edge*0.15);
            const Vec2 candidate=add(mul(add(a,b),0.5),mul(normal,offset));
            if (classify_loop(ring,candidate,tolerance)==Location::Inside)
                return candidate;
        }
    }
    return std::nullopt;
}

std::optional<Vec2> region_probe(const PartitionRegion& region,double tolerance)
{
    // Do NOT stop at the first point inside Outer: it may be in an
    // untouched Hole. Probe actual material (Outer minus Inner Loops).
    const auto& ring=region.outer.points;
    for (std::size_t i=0;i<ring.size();++i)
    {
        const Vec2 from=ring[i],to=ring[(i+1)%ring.size()];
        const Vec2 edge=sub(to,from);
        const double side=length(edge);
        if (side<=2*tolerance) continue;
        const Vec2 inward={-edge.y/side,edge.x/side};
        for (double factor:{2.0,4.0,8.0})
        {
            const double delta=std::min(factor*tolerance,side*0.15);
            const Vec2 point=add(mul(add(from,to),0.5),mul(inward,delta));
            if (inside_region(region,point,tolerance)) return point;
        }
    }
    return std::nullopt;
}

bool segment_conflict(const PlanarGraph& graph,const GraphEdge& first,
                      const GraphEdge& second,double tolerance)
{
    const Vec2 a=graph.vertices[first.first].position;
    const Vec2 b=graph.vertices[first.second].position;
    const Vec2 c=graph.vertices[second.first].position;
    const Vec2 d=graph.vertices[second.second].position;
    if (std::max(a.x,b.x)<std::min(c.x,d.x)-tolerance ||
        std::max(c.x,d.x)<std::min(a.x,b.x)-tolerance ||
        std::max(a.y,b.y)<std::min(c.y,d.y)-tolerance ||
        std::max(c.y,d.y)<std::min(a.y,b.y)-tolerance) return false;
    const bool shared=first.first==second.first ||
        first.first==second.second || first.second==second.first ||
        first.second==second.second;
    const Vec2 u=sub(b,a),v=sub(d,c),w=sub(c,a);
    const double lu=length(u),lv=length(v);
    if (lu<=tolerance||lv<=tolerance) return true;
    const double den=cross(u,v);
    if (std::abs(den)<=tolerance*std::max(lu,lv))
    {
        if (std::abs(cross(w,u))>tolerance*lu) return false;
        const double first_t=dot(w,u)/(lu*lu);
        const double last_t=dot(sub(d,a),u)/(lu*lu);
        const double overlap=std::min(1.0,std::max(first_t,last_t)) -
                             std::max(0.0,std::min(first_t,last_t));
        return overlap*lu>tolerance;
    }
    const double t=cross(w,v)/den;
    const double q=cross(w,u)/den;
    if (t < -tolerance/lu || t>1.0+tolerance/lu ||
        q < -tolerance/lv || q>1.0+tolerance/lv) return false;
    // Shared graph vertex is a legitimate intersection. A T-junction
    // whose edge was never split is NOT.
    const bool at_endpoint_first=t<=tolerance/lu ||
                                 t>=1.0-tolerance/lu;
    const bool at_endpoint_second=q<=tolerance/lv ||
                                  q>=1.0-tolerance/lv;
    return !(shared && at_endpoint_first && at_endpoint_second);
}

bool simple_cycle(const RegionLoop& loop,const CycleWalk& walk,
                  double tolerance)
{
    if (loop.points.size()<3 ||
        loop.points.size()!=loop.halfedge_ids.size()) return false;
    std::set<std::size_t> vertices;
    for (std::size_t he:loop.halfedge_ids)
    {
        if (he>=walk.graph.half_edges.size()) return false;
        vertices.insert(walk.graph.half_edges[he].origin);
        const GraphHalfEdge& edge=walk.graph.half_edges[he];
        if (distance(walk.graph.vertices[edge.origin].position,
                     walk.graph.vertices[edge.destination].position)
                     <=tolerance) return false;
    }
    return vertices.size()==loop.points.size();
}
} // namespace

ValidationResult validate_partition(const NormalizedFace& source,
                                    const CycleWalk& walk,
                                    const RegionExtraction& extraction,
                                    double tolerance)
{
    if (!std::isfinite(tolerance)||tolerance<=0.0 ||
        source.outer.points.size()<3 ||
        extraction.region_of_cycle.size()!=walk.cycles.size())
        return {{},ValidationError::InvalidInput};
    if (extraction.regions.size()<2)
        return {{},ValidationError::NoSplit};
    const PlanarGraph& graph=walk.graph;
    if (graph.edges.size()>4096)
        return {{},ValidationError::TooManyEdges};

    // Topological sanity: no nonsplit crossings, duplicate collinear
    // edges, or T-junctions. Shared endpoints are allowed.
    for (std::size_t i=0;i<graph.edges.size();++i)
        for (std::size_t j=i+1;j<graph.edges.size();++j)
            if (segment_conflict(graph,graph.edges[i],graph.edges[j],tolerance))
                return {{},ValidationError::InvalidBoundary};

    const double source_area=std::abs(source.outer.signed_area);
    double expected=source_area;
    for (const NormalizedLoop& hole:source.holes)
        expected-=std::abs(hole.signed_area);
    if (!std::isfinite(expected)||expected<=0.0)
        return {{},ValidationError::InvalidInput};
    const double area_tolerance=std::max(
        tolerance*tolerance,expected*1.0e-8);
    double actual=0.0;
    for (const PartitionRegion& region:extraction.regions)
    {
        if (!simple_cycle(region.outer,walk,tolerance))
            return {{},ValidationError::InvalidBoundary};
        for (const RegionLoop& hole:region.holes)
            if (!simple_cycle(hole,walk,tolerance))
                return {{},ValidationError::InvalidBoundary};
        if (!std::isfinite(region.net_area) ||
            region.net_area<=area_tolerance)
            return {{},ValidationError::AreaTooSmall};
        actual+=region.net_area;
    }
    if (std::abs(actual-expected)>area_tolerance)
        return {{},ValidationError::AreaNotConserved};

    // Each boundary HalfEdge borders material on exactly one side.
    // Each new interior Cut has TWO different material owners.
    std::vector<SharedBoundary> shared;
    for (std::size_t i=0;i<graph.edges.size();++i)
    {
        const GraphEdge& e=graph.edges[i];
        const std::size_t a=walk.cycle_of_halfedge[2*i];
        const std::size_t b=walk.cycle_of_halfedge[2*i+1];
        if (a>=walk.cycles.size()||b>=walk.cycles.size())
            return {{},ValidationError::InvalidOwnership};
        const bool material_a=walk.cycles[a].material_on_left;
        const bool material_b=walk.cycles[b].material_on_left;
        const std::size_t region_a=extraction.region_of_cycle[a];
        const std::size_t region_b=extraction.region_of_cycle[b];
        if (e.kind==EdgeKind::Cut)
        {
            if (!material_a||!material_b ||
                region_a==NO_EDGE||region_b==NO_EDGE ||
                region_a==region_b)
                return {{},ValidationError::CutNotShared};
            shared.push_back({
                i,region_a,region_b,
                graph.vertices[e.first].position,
                graph.vertices[e.second].position
            });
        }
        else if (material_a==material_b ||
                 (material_a && region_a==NO_EDGE) ||
                 (material_b && region_b==NO_EDGE))
            return {{},ValidationError::InvalidOwnership};
    }
    if (shared.empty()) return {{},ValidationError::NoSplit};

    // Probe every child in the original domain, and ensure it is not
    // also inside another child. Boundary coincidence is handled by
    // exact shared-edge ownership above.
    for (std::size_t i=0;i<extraction.regions.size();++i)
    {
        const PartitionRegion& region=extraction.regions[i];
        const auto probe=region_probe(region,tolerance);
        if (!probe || classify_domain(source,*probe,tolerance)!=Location::Inside)
            return {{},ValidationError::InvalidBoundary};
        for (std::size_t j=0;j<extraction.regions.size();++j)
            if (j!=i && inside_region(extraction.regions[j],*probe,tolerance))
                return {{},ValidationError::RegionOverlap};
        for (const RegionLoop& hole:region.holes)
        {
            const auto inside_hole=ring_probe(hole.points,true,tolerance);
            if (!inside_hole || inside_region(region,*inside_hole,tolerance))
                return {{},ValidationError::InvalidBoundary};
        }
    }
    // Holes cannot be accidentally filled, including when a Cut splits
    // one Hole into pieces of two child Outer boundaries.
    for (const NormalizedLoop& hole:source.holes)
    {
        const auto sample=ring_probe(hole.points,true,tolerance);
        if (!sample) return {{},ValidationError::HoleNotPreserved};
        for (const PartitionRegion& region:extraction.regions)
            if (inside_region(region,*sample,tolerance))
                return {{},ValidationError::HoleNotPreserved};
    }

    ValidatedPartition result;
    result.children=extraction.regions;
    result.shared_cuts=std::move(shared);
    result.original_area=expected;
    return {std::move(result),ValidationError::None};
}

PartitionAttempt attempt_partition(const NormalizedFace& source,
                                   const SplitCandidate& candidate,
                                   double tolerance)
{
    PartitionAttempt attempt;
    const auto traced=trace_split(source,candidate,tolerance);
    if (!traced.trace)
    {
        attempt.failed_stage=AttemptStage::Intersections;
        attempt.trace_error=traced.error;
        return attempt;
    }
    auto built=build_graph(source,*traced.trace,tolerance);
    if (!built.graph)
    {
        attempt.failed_stage=AttemptStage::Graph;
        attempt.graph_error=built.error;
        return attempt;
    }
    auto walked=walk_cycles(std::move(*built.graph),source,tolerance);
    if (!walked.walk)
    {
        attempt.failed_stage=AttemptStage::Cycles;
        attempt.cycle_error=walked.error;
        return attempt;
    }
    auto regions=reconstruct_regions(*walked.walk,tolerance);
    if (!regions.extraction)
    {
        attempt.failed_stage=AttemptStage::Regions;
        attempt.region_error=regions.error;
        return attempt;
    }
    auto validated=validate_partition(
        source,*walked.walk,*regions.extraction,tolerance);
    if (!validated.partition)
    {
        attempt.failed_stage=AttemptStage::Validation;
        attempt.validation_error=validated.error;
        return attempt;
    }
    attempt.partition=std::move(validated.partition);
    return attempt;
}
} // namespace IndoorGMLAdjacencyNative::FloorPartition
