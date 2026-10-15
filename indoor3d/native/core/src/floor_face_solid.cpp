#include "floor_face_solid.h"
#include "floor_polygon_intersections.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <numeric>
#include <utility>

namespace IndoorGMLAdjacencyNative
{
namespace
{
using FloorPartition::Vec2;
using FloorPartition::Location;
Vec3 sub(Vec3 a,Vec3 b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
Vec3 add(Vec3 a,Vec3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
Vec3 mul(Vec3 a,double k) { return {a.x*k,a.y*k,a.z*k}; }
double dot(Vec3 a,Vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
double length(Vec3 v) { return std::sqrt(dot(v,v)); }
double coordinate(Vec3 v,int axis)
{
    return axis==0?v.x:(axis==1?v.y:v.z);
}
Aabb empty_box()
{
    const double infinity=std::numeric_limits<double>::infinity();
    return {{infinity,infinity,infinity},{-infinity,-infinity,-infinity}};
}
void include(Aabb& box,Vec3 p)
{
    box.minimum.x=std::min(box.minimum.x,p.x);
    box.minimum.y=std::min(box.minimum.y,p.y);
    box.minimum.z=std::min(box.minimum.z,p.z);
    box.maximum.x=std::max(box.maximum.x,p.x);
    box.maximum.y=std::max(box.maximum.y,p.y);
    box.maximum.z=std::max(box.maximum.z,p.z);
}
void include(Aabb& a,const Aabb& b)
{
    include(a,b.minimum);include(a,b.maximum);
}
bool hit_box(const Aabb& box,Vec3 origin,Vec3 direction,
             double max_t,double tol)
{
    double low=0.0,high=max_t;
    for (int k=0;k<3;++k)
    {
        const double p=coordinate(origin,k),d=coordinate(direction,k);
        const double min=coordinate(box.minimum,k)-tol;
        const double max=coordinate(box.maximum,k)+tol;
        if (std::abs(d)<1.0e-12)
        {
            if (p<min||p>max) return false;
            continue;
        }
        double a=(min-p)/d,b=(max-p)/d;
        if (a>b) std::swap(a,b);
        low=std::max(low,a);
        high=std::min(high,b);
        if (high<low) return false;
    }
    return true;
}
double box_distance(const Aabb& b,Vec3 p)
{
    double sum=0.0;
    for (int axis=0;axis<3;++axis)
    {
        const double v=coordinate(p,axis);
        const double below=coordinate(b.minimum,axis)-v;
        const double above=v-coordinate(b.maximum,axis);
        const double d=std::max({0.0,below,above});
        sum+=d*d;
    }
    return std::sqrt(sum);
}
double point_segment_distance(Vec3 p,Vec3 a,Vec3 b)
{
    const Vec3 edge=sub(b,a);
    const double d=dot(edge,edge);
    const double t=d>0.0?std::clamp(dot(sub(p,a),edge)/d,0.0,1.0):0.0;
    return length(sub(p,add(a,mul(edge,t))));
}
bool finite(Vec3 p)
{
    return std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z);
}
} // namespace

FaceSolid::FaceSolid(const CellData& cell,double tolerance)
    : tolerance_(tolerance)
{
    if (!std::isfinite(tolerance)||tolerance<=0.0 ||
        cell.faces.empty()) return;
    surfaces_.reserve(cell.faces.size());
    for (const FaceData& face:cell.faces)
    {
        // A malformed Face cannot be silently ignored: omitting it
        // would change solid parity and permit LOS across a wall.
        const auto prepared=face.has_plane ?
            FloorPartition::prepare(face.plane,face.outer_loop(),face.holes(),tolerance) :
            FloorPartition::prepare(face.normal,face.outer_loop(),face.holes(),tolerance);
        if (!prepared.face) return;
        Surface surface;
        surface.face=*prepared.face;
        surface.box=empty_box();
        const auto expand=[&](const FloorPartition::NormalizedLoop& ring) {
            for (Vec2 p:ring.points)
                include(surface.box,surface.face.frame.lift(p));
        };
        expand(surface.face.outer);
        for (const auto& hole:surface.face.holes)expand(hole);
        surfaces_.push_back(std::move(surface));
    }
    order_.resize(surfaces_.size());
    std::iota(order_.begin(),order_.end(),0);
    nodes_.reserve(surfaces_.size()*2);
    build(0,order_.size());
    valid_=!nodes_.empty();
}

std::size_t FaceSolid::build(std::size_t begin,std::size_t end)
{
    const std::size_t id=nodes_.size();
    nodes_.push_back({});
    Aabb bounds=empty_box();
    for (std::size_t i=begin;i<end;++i)
        include(bounds,surfaces_[order_[i]].box);
    nodes_[id].box=bounds;
    if (end-begin<=6)
    {
        nodes_[id].begin=begin;
        nodes_[id].count=end-begin;
        return id;
    }
    const Vec3 ext=sub(bounds.maximum,bounds.minimum);
    const int axis=ext.x>=ext.y&&ext.x>=ext.z?0:(ext.y>=ext.z?1:2);
    const std::size_t middle=begin+(end-begin)/2;
    std::nth_element(order_.begin()+begin,order_.begin()+middle,
                     order_.begin()+end,[&](std::size_t a,std::size_t b) {
                         const auto center=[&](std::size_t index) {
                             const Aabb& box=surfaces_[index].box;
                             return coordinate(box.minimum,axis)+
                                    coordinate(box.maximum,axis);
                         };
                         return center(a)<center(b);
                     });
    const std::size_t left=build(begin,middle);
    const std::size_t right=build(middle,end);
    nodes_[id].left=left;
    nodes_[id].right=right;
    return id;
}

double FaceSolid::face_distance(const Surface& surface,Vec3 p) const
{
    const auto& face=surface.face;
    const double height=dot(sub(p,face.frame.origin),face.frame.n);
    const Vec3 projected=sub(p,mul(face.frame.n,height));
    const Vec2 q=face.frame.project(projected);
    const auto outer=FloorPartition::classify_loop(
        face.outer.points,q,tolerance_);
    if (outer!=Location::Outside)
    {
        bool hole_interior=false;
        for (const auto& hole:face.holes)
            if (FloorPartition::classify_loop(
                    hole.points,q,tolerance_)==Location::Inside)
            {
                hole_interior=true;
                break;
            }
        if (!hole_interior) return std::abs(height);
    }
    double best=std::numeric_limits<double>::infinity();
    const auto measure=[&](const FloorPartition::NormalizedLoop& ring) {
        for (std::size_t i=0;i<ring.points.size();++i)
        {
            const Vec3 a=face.frame.lift(ring.points[i]);
            const Vec3 b=face.frame.lift(
                ring.points[(i+1)%ring.points.size()]);
            best=std::min(best,point_segment_distance(p,a,b));
        }
    };
    measure(face.outer);
    for (const auto& hole:face.holes) measure(hole);
    return best;
}
double FaceSolid::closest(std::size_t node,Vec3 point,double best) const
{
    const Node& n=nodes_[node];
    if (box_distance(n.box,point)>=best) return best;
    if (n.leaf())
    {
        for (std::size_t i=n.begin;i<n.begin+n.count;++i)
            best=std::min(best,face_distance(surfaces_[order_[i]],point));
        return best;
    }
    const double l=box_distance(nodes_[n.left].box,point);
    const double r=box_distance(nodes_[n.right].box,point);
    if (l<r)
    {
        best=closest(n.left,point,best);
        best=closest(n.right,point,best);
    }
    else
    {
        best=closest(n.right,point,best);
        best=closest(n.left,point,best);
    }
    return best;
}
double FaceSolid::nearest_distance(Vec3 point) const
{
    if (!valid_||!finite(point))
        return std::numeric_limits<double>::infinity();
    return closest(0,point,std::numeric_limits<double>::infinity());
}

void FaceSolid::collect_hits(std::size_t node,Vec3 origin,
                             Vec3 direction,double maximum,double tol,
                             std::vector<double>& hits,bool& ambiguous) const
{
    const Node& n=nodes_[node];
    if (!hit_box(n.box,origin,direction,maximum,tol)) return;
    if (!n.leaf())
    {
        collect_hits(n.left,origin,direction,maximum,tol,hits,ambiguous);
        collect_hits(n.right,origin,direction,maximum,tol,hits,ambiguous);
        return;
    }
    for (std::size_t i=n.begin;i<n.begin+n.count;++i)
    {
        const Surface& surface=surfaces_[order_[i]];
        if (!hit_box(surface.box,origin,direction,maximum,tol)) continue;
        const auto& frame=surface.face.frame;
        const double denominator=dot(frame.n,direction);
        const double numerator=dot(frame.n,sub(frame.origin,origin));
        if (std::abs(denominator)<1.0e-12)
        {
            if (std::abs(numerator)<=tol) ambiguous=true;
            continue;
        }
        const double t=numerator/denominator;
        if (t<=tol || t>=maximum-tol) continue;
        const Vec3 hit=add(origin,mul(direction,t));
        const Vec2 projected=frame.project(hit);
        const Location location=FloorPartition::classify_domain(
            surface.face,projected,tol);
        if (location==Location::Boundary)
        {
            ambiguous=true;
            continue;
        }
        if (location==Location::Inside) hits.push_back(t);
    }
}

bool FaceSolid::inside(Vec3 point,double tolerance) const
{
    if (!valid_||!finite(point)||!std::isfinite(tolerance) ||
        tolerance<=0.0 || nearest_distance(point)<=tolerance)
        return false;
    // Non-axis-aligned fixed rays reduce vertex/edge coincidence.
    // Three votes distinguish a true closed solid from a single
    // unlucky tangent/coplanar ray. Coincident coplanar Face hits are
    // clustered by distance so they count as ONE boundary crossing.
    constexpr std::array<Vec3,3> directions{{
        {0.8427009716,0.3350193661,0.4206795574},
        {0.2810891032,0.9018327334,0.3284182091},
        {0.3991821373,0.2420895114,0.8844175123}
    }};
    int successful=0,positive=0;
    for (Vec3 raw:directions)
    {
        const Vec3 d=mul(raw,1.0/length(raw));
        std::vector<double> hits;
        bool ambiguous=false;
        collect_hits(0,point,d,std::numeric_limits<double>::max()/4.0,
                     tolerance,hits,ambiguous);
        if (ambiguous) continue;
        std::sort(hits.begin(),hits.end());
        std::size_t count=0;
        for (double hit:hits)
        {
            if (count==0 || hit-hits[count-1]>tolerance*4.0)
                hits[count++]=hit;
        }
        ++successful;
        if (count%2==1) ++positive;
    }
    return successful>=2 && positive*2>successful;
}

bool FaceSolid::visible(Vec3 first,Vec3 last,double tolerance) const
{
    if (!valid_||!finite(first)||!finite(last)) return false;
    const Vec3 segment=sub(last,first);
    const double distance=length(segment);
    if (distance<=2*tolerance) return false;
    if (!inside(first,tolerance)||!inside(last,tolerance))
        return false;
    const Vec3 direction=mul(segment,1.0/distance);
    std::vector<double> hits;
    bool ambiguous=false;
    collect_hits(0,first,direction,distance,tolerance,hits,ambiguous);
    if (ambiguous||!hits.empty()) return false;
    for (double t:{0.125,0.25,0.5,0.75,0.875})
        if (!inside(add(first,mul(segment,t)),tolerance))
            return false;
    return true;
}
} // namespace IndoorGMLAdjacencyNative
