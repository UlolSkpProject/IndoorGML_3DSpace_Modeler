#include "floor_polygon_reference.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <tuple>
#include <utility>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
namespace
{
Vec3 sub(Vec3 a,Vec3 b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
Vec3 add(Vec3 a,Vec3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
Vec3 mul(Vec3 a,double t) { return {a.x*t,a.y*t,a.z*t}; }
double dot(Vec3 a,Vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
Vec3 cross(Vec3 a,Vec3 b)
{
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,
            a.x*b.y-a.y*b.x};
}
double length(Vec3 a) { return std::sqrt(dot(a,a)); }
double distance(Vec3 a,Vec3 b) { return length(sub(a,b)); }

struct Moment {
    double signed_area=0;
    Vec2 centroid;
};
Moment ring_moment(const NormalizedLoop& ring)
{
    if (ring.points.size()<3) return {};
    const Vec2 base=ring.points.front();
    double cross_sum=0,wx=0,wy=0;
    for (std::size_t i=0;i<ring.points.size();++i)
    {
        const Vec2 a=ring.points[i],b=ring.points[(i+1)%ring.points.size()];
        const double ax=a.x-base.x,ay=a.y-base.y;
        const double bx=b.x-base.x,by=b.y-base.y;
        const double det=ax*by-ay*bx;
        cross_sum+=det;
        wx+=(ax+bx)*det;
        wy+=(ay+by)*det;
    }
    if (std::abs(cross_sum)<=1.0e-15) return {};
    return {cross_sum*0.5,{base.x+wx/(3.0*cross_sum),
                            base.y+wy/(3.0*cross_sum)}};
}
std::optional<Vec2> face_centroid(const NormalizedFace& face,double tol)
{
    const Moment outer=ring_moment(face.outer);
    double area=outer.signed_area;
    Vec2 moment={outer.centroid.x*area,outer.centroid.y*area};
    for (const NormalizedLoop& hole:face.holes)
    {
        const Moment inner=ring_moment(hole);
        area+=inner.signed_area;
        moment.x+=inner.centroid.x*inner.signed_area;
        moment.y+=inner.centroid.y*inner.signed_area;
    }
    if (!std::isfinite(area)||area<=tol*tol) return std::nullopt;
    const Vec2 p{moment.x/area,moment.y/area};
    if (!std::isfinite(p.x)||!std::isfinite(p.y) ||
        classify_domain(face,p,tol)!=Location::Inside) return std::nullopt;
    return p;
}
struct EdgePiece {
    std::size_t leaf=0;
    Vec3 a;
    Vec3 b;
};
struct SharedSegment {
    std::size_t a=0,b=0;
    Vec3 start;
    Vec3 end;
};

std::optional<SharedSegment> shared_overlap(
    const EdgePiece& first,const EdgePiece& second,double tol)
{
    if (first.leaf==second.leaf) return std::nullopt;
    const Vec3 u=sub(first.b,first.a),v=sub(second.b,second.a);
    const double lu=length(u),lv=length(v);
    if (lu<=tol||lv<=tol) return std::nullopt;
    const Vec3 direction=mul(u,1.0/lu);
    // Parallel + co-linear, not just coplanar.
    if (length(cross(direction,v))>tol ||
        length(cross(direction,sub(second.a,first.a)))>tol)
        return std::nullopt;
    const double begin=std::max(0.0,std::min(
        dot(sub(second.a,first.a),direction),
        dot(sub(second.b,first.a),direction)));
    const double end=std::min(lu,std::max(
        dot(sub(second.a,first.a),direction),
        dot(sub(second.b,first.a),direction)));
    if (end-begin<=tol) return std::nullopt;
    return SharedSegment{
        std::min(first.leaf,second.leaf),
        std::max(first.leaf,second.leaf),
        add(first.a,mul(direction,begin)),
        add(first.a,mul(direction,end))
    };
}
std::vector<EdgePiece> boundary_edges(
    const std::vector<PartitionLeaf>& leaves)
{
    std::vector<EdgePiece> edges;
    for (std::size_t leaf=0;leaf<leaves.size();++leaf)
    {
        const NormalizedFace& f=leaves[leaf].polygon;
        const auto emit=[&](const NormalizedLoop& ring) {
            for (std::size_t i=0;i<ring.points.size();++i)
            {
                const Vec3 a=f.frame.lift(ring.points[i]);
                const Vec3 b=f.frame.lift(
                    ring.points[(i+1)%ring.points.size()]);
                edges.push_back({leaf,a,b});
            }
        };
        emit(f.outer);
        for (const NormalizedLoop& ring:f.holes) emit(ring);
    }
    return edges;
}
} // namespace

ReferenceSeeds generate_reference_seeds(
    const std::vector<PartitionLeaf>& completed,
    double tolerance,ReferenceOptions options)
{
    ReferenceSeeds result;
    if (!std::isfinite(tolerance)||tolerance<=0.0 ||
        !std::isfinite(options.world_z_offset) ||
        options.max_points==0) return result;
    const auto emit=[&](Vec3 point,SeedKind kind,
                        std::size_t a,std::size_t b) {
        if (result.points.size()>=options.max_points)
        {
            ++result.limit_reached;
            return;
        }
        point.z+=options.world_z_offset;
        for (const Seed& existing:result.points)
            if (distance(existing.position,point)<=tolerance)
                return; // deterministic location dedup; State later.
        result.points.push_back({point,kind,a,b});
    };
    // Centroids first; the first accepted candidate is the provisional
    // State in Phase 10, independently of any global State search.
    for (std::size_t i=0;i<completed.size();++i)
    {
        const auto p=face_centroid(completed[i].polygon,tolerance);
        if (!p)
        {
            ++result.rejected_centroids;
            continue;
        }
        emit(completed[i].polygon.frame.lift(*p),
             SeedKind::PolygonCentroid,i,NO_EDGE);
    }

    const std::vector<EdgePiece> edges=boundary_edges(completed);
    // Group all partially overlapping collinear fragments by ownership
    // pair. This handles T-junctions and child splits without assuming
    // equal edge segmentation on both sides of a shared boundary.
    std::map<std::pair<std::size_t,std::size_t>,
             std::vector<SharedSegment>> shared;
    for (std::size_t i=0;i<edges.size();++i)
        for (std::size_t j=i+1;j<edges.size();++j)
        {
            const auto overlap=shared_overlap(edges[i],edges[j],tolerance);
            if (overlap)
                shared[{overlap->a,overlap->b}].push_back(*overlap);
        }
    for (auto& entry:shared)
    {
        auto& pieces=entry.second;
        // Merge geometrically collinear touching fragments into a
        // maximal shared line; one midpoint PER maximal boundary.
        bool changed=true;
        while (changed)
        {
            changed=false;
            for (std::size_t i=0;i<pieces.size() && !changed;++i)
                for (std::size_t j=i+1;j<pieces.size();++j)
                {
                    const Vec3 old_start=pieces[i].start;
                    const Vec3 axis=sub(pieces[i].end,old_start);
                    const double n=length(axis);
                    if (n<=tolerance) continue;
                    const Vec3 d=mul(axis,1.0/n);
                    const Vec3 offset=sub(pieces[j].start,old_start);
                    const Vec3 end_offset=sub(pieces[j].end,old_start);
                    if (length(cross(d,offset))>tolerance ||
                        length(cross(d,end_offset))>tolerance)
                        continue;
                    const double lo=std::min(dot(offset,d),dot(end_offset,d));
                    const double hi=std::max(dot(offset,d),dot(end_offset,d));
                    if (lo>n+tolerance || hi < -tolerance)
                        continue;
                    const double begin=std::min(0.0,lo);
                    const double end=std::max(n,hi);
                    pieces[i].start=add(old_start,mul(d,begin));
                    pieces[i].end=add(old_start,mul(d,end));
                    pieces.erase(pieces.begin()+j);
                    changed=true;
                    break; // restart: merged fragment can bridge older pieces
                }
        }
        for (const SharedSegment& segment:pieces)
        {
            ++result.shared_segments;
            emit(mul(add(segment.start,segment.end),0.5),
                 SeedKind::SharedEdgeMidpoint,
                 segment.a,segment.b);
        }
    }
    return result;
}
} // namespace IndoorGMLAdjacencyNative::FloorPartition
