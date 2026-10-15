#include "floor_polygon_intersections.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
namespace
{
Vec2 add(Vec2 a,Vec2 b) { return {a.x+b.x,a.y+b.y}; }
Vec2 sub(Vec2 a,Vec2 b) { return {a.x-b.x,a.y-b.y}; }
Vec2 mul(Vec2 a,double t) { return {a.x*t,a.y*t}; }
double dot(Vec2 a,Vec2 b) { return a.x*b.x+a.y*b.y; }
double cross(Vec2 a,Vec2 b) { return a.x*b.y-a.y*b.x; }
double length(Vec2 a) { return std::hypot(a.x,a.y); }
double dist(Vec2 a,Vec2 b) { return length(sub(a,b)); }
bool finite(Vec2 p) { return std::isfinite(p.x)&&std::isfinite(p.y); }
double clamp01(double t) { return std::clamp(t,0.0,1.0); }
bool near_segment(Vec2 p,Vec2 a,Vec2 b,double tol)
{
    const Vec2 d=sub(b,a);
    const double n=dot(d,d);
    if (n<=tol*tol) return dist(p,a)<=tol;
    const double t=clamp01(dot(sub(p,a),d)/n);
    return dist(p,add(a,mul(d,t)))<=tol;
}
bool bbox_may_intersect(Vec2 a,Vec2 b,Bounds2 bounds,double tol)
{
    return !(std::max(a.x,b.x)<bounds.minimum.x-tol ||
             std::min(a.x,b.x)>bounds.maximum.x+tol ||
             std::max(a.y,b.y)<bounds.minimum.y-tol ||
             std::min(a.y,b.y)>bounds.maximum.y+tol);
}
struct RawHit {
    Vec2 p;
    double ray_t=0;
    double fraction=0;
    bool vertex=false;
    bool collinear=false;
};
std::vector<RawHit> ray_edge(
    Vec2 start,Vec2 direction,Vec2 a,Vec2 b,double tol)
{
    std::vector<RawHit> result;
    const Vec2 edge=sub(b,a);
    const double el=length(edge);
    if (el<=tol) return result;
    const Vec2 offset=sub(a,start);
    const double denominator=cross(direction,edge);
    const double bound=tol*el;
    if (std::abs(denominator)<=bound)
    {
        if (std::abs(cross(offset,direction))>tol) return result;
        // Collinear overlap is represented by both edge endpoints.
        // Phase 4 consolidates it with the EXISTING boundary, not a
        // duplicate Cut edge.
        for (int i=0;i<2;++i)
        {
            const Vec2 p=i==0?a:b;
            const double t=dot(sub(p,start),direction);
            if (t>=-tol)
                result.push_back({p,std::max(0.0,t),double(i),true,true});
        }
        return result;
    }
    const double t=cross(offset,edge)/denominator;
    const double u=cross(offset,direction)/denominator;
    const double epsilon=tol/el;
    if (t>=-tol && u>=-epsilon && u<=1.0+epsilon)
        result.push_back({
            add(start,mul(direction,std::max(0.0,t))),
            std::max(0.0,t),clamp01(u),
            u<=epsilon||u>=1.0-epsilon,false
        });
    return result;
}
std::vector<BoundaryHit> gather_ray(
    const NormalizedLoop& loop,Vec2 origin,Vec2 direction,double tol)
{
    std::vector<BoundaryHit> result;
    for (std::size_t i=0;i<loop.points.size();++i)
    {
        const Vec2 a=loop.points[i],b=loop.points[(i+1)%loop.points.size()];
        for (const RawHit& hit:ray_edge(origin,direction,a,b,tol))
            result.push_back({
                hit.p,hit.ray_t,
                loop.hole?LoopKind::Inner:LoopKind::Outer,
                loop.source_loop_index,i,hit.fraction,
                hit.vertex,hit.collinear
            });
    }
    return result;
}
std::optional<double> first_outer_hit(
    const NormalizedLoop& outer,Vec2 origin,Vec2 direction,double tol)
{
    const auto hits=gather_ray(outer,origin,direction,tol);
    double nearest=std::numeric_limits<double>::infinity();
    for (const auto& hit:hits)
        if (hit.distance>tol && hit.distance<nearest) nearest=hit.distance;
    if (!std::isfinite(nearest)) return std::nullopt;
    return nearest;
}
} // namespace

Location classify_loop(const std::vector<Vec2>& ring,Vec2 p,double tol)
{
    if (ring.size()<3) return Location::Outside;
    bool inside=false;
    for (std::size_t i=0,j=ring.size()-1;i<ring.size();j=i++)
    {
        const Vec2 a=ring[j],b=ring[i];
        if (near_segment(p,a,b,tol)) return Location::Boundary;
        if ((a.y>p.y)!=(b.y>p.y))
        {
            const double x=a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y);
            if (x>p.x) inside=!inside;
        }
    }
    return inside?Location::Inside:Location::Outside;
}

Location classify_domain(const NormalizedFace& face,Vec2 p,double tol)
{
    const auto outer=classify_loop(face.outer.points,p,tol);
    if (outer!=Location::Inside) return outer;
    for (const auto& hole:face.holes)
    {
        if (p.x<hole.bounds.minimum.x-tol ||
            p.x>hole.bounds.maximum.x+tol ||
            p.y<hole.bounds.minimum.y-tol ||
            p.y>hole.bounds.maximum.y+tol) continue;
        const auto location=classify_loop(hole.points,p,tol);
        if (location==Location::Boundary) return Location::Boundary;
        if (location==Location::Inside) return Location::Outside;
    }
    return Location::Inside;
}

TraceResult trace_split(const NormalizedFace& face,
                        const SplitCandidate& candidate,double tol)
{
    if (!std::isfinite(tol)||tol<=0.0 ||
        !finite(candidate.origin)||!finite(candidate.primary_direction))
        return {{},TraceError::InvalidInput};
    const double dlen=length(candidate.primary_direction);
    if (dlen<=1.0e-12) return {{},TraceError::InvalidInput};
    const Vec2 axis=mul(candidate.primary_direction,1.0/dlen);
    const auto forward=first_outer_hit(face.outer,candidate.origin,axis,tol);
    if (!forward) return {{},TraceError::MissingOuterHit};
    SplitTrace trace;
    trace.first=candidate.origin;
    trace.last=add(candidate.origin,mul(axis,*forward));
    if (candidate.bidirectional)
    {
        const auto reverse=first_outer_hit(face.outer,candidate.origin,mul(axis,-1),tol);
        if (!reverse) return {{},TraceError::MissingOuterHit};
        trace.first=add(candidate.origin,mul(axis,-*reverse));
    }
    const Vec2 chord=sub(trace.last,trace.first);
    const double chord_length=length(chord);
    if (chord_length<=tol) return {{},TraceError::InvalidInput};
    const Vec2 unit=mul(chord,1.0/chord_length);

    trace.intersections=gather_ray(face.outer,trace.first,unit,tol);
    for (const auto& hole:face.holes)
    {
        if (!bbox_may_intersect(trace.first,trace.last,hole.bounds,tol))
            continue; // AABB is a BROAD phase only; test actual edges next
        ++trace.inspected_holes;
        const auto candidates=gather_ray(hole,trace.first,unit,tol);
        trace.intersections.insert(
            trace.intersections.end(),candidates.begin(),candidates.end());
    }
    auto& hits=trace.intersections;
    hits.erase(std::remove_if(hits.begin(),hits.end(),
        [&](const BoundaryHit& hit) {
            return hit.distance>chord_length+tol || hit.distance < -tol;
        }),hits.end());
    std::sort(hits.begin(),hits.end(),[](const BoundaryHit& a,const BoundaryHit& b) {
        if (a.distance!=b.distance) return a.distance<b.distance;
        if (a.loop_index!=b.loop_index) return a.loop_index<b.loop_index;
        return a.edge_index<b.edge_index;
    });

    std::vector<double> stops{0.0,chord_length};
    stops.reserve(hits.size()+2);
    for (const auto& hit:hits)
        stops.push_back(std::clamp(hit.distance,0.0,chord_length));
    std::sort(stops.begin(),stops.end());
    stops.erase(std::unique(stops.begin(),stops.end(),
        [tol](double a,double b) { return std::abs(a-b)<=tol; }),
        stops.end());

    // Classify all chord subintervals. No Hole interior ever creates Cut.
    for (std::size_t i=1;i<stops.size();++i)
    {
        const double a=stops[i-1],b=stops[i];
        if (b-a<=tol) continue;
        const Vec2 middle=add(trace.first,mul(unit,(a+b)*0.5));
        if (classify_domain(face,middle,tol)!=Location::Inside) continue;
        trace.material_intervals.push_back({
            add(trace.first,mul(unit,a)),
            add(trace.first,mul(unit,b)),a,b
        });
    }
    if (trace.material_intervals.empty())
        return {{},TraceError::NoMaterialSegment};
    return {std::move(trace),TraceError::None};
}
} // namespace IndoorGMLAdjacencyNative::FloorPartition
