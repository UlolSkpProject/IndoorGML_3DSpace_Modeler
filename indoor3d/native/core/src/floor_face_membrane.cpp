#include "floor_face_solid.h"
#include "floor_polygon_intersections.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
namespace
{
using FloorPartition::Vec2;
using FloorPartition::Location;
Vec3 plus(Vec3 a,Vec3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
Vec3 minus(Vec3 a,Vec3 b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
Vec3 times(Vec3 a,double k) { return {a.x*k,a.y*k,a.z*k}; }
double scalar(Vec3 a,Vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
Vec3 product(Vec3 a,Vec3 b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
double magnitude(Vec3 a) { return std::sqrt(scalar(a,a)); }
double orient(Vec2 a,Vec2 b,Vec2 p)
{ return (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x); }
bool between(double x,double a,double b,double t)
{ return x>=std::min(a,b)-t && x<=std::max(a,b)+t; }
bool segment_touch(Vec2 a,Vec2 b,Vec2 c,Vec2 d,double tol)
{
    const double x=orient(a,b,c),y=orient(a,b,d),z=orient(c,d,a),w=orient(c,d,b);
    if(((x>tol&&y< -tol)||(x< -tol&&y>tol)) &&
       ((z>tol&&w< -tol)||(z< -tol&&w>tol)))return true;
    const auto on=[&](Vec2 p,Vec2 u,Vec2 v) {
        return std::abs(orient(u,v,p))<=tol*std::max(1.0,std::hypot(v.x-u.x,v.y-u.y)) &&
            between(p.x,u.x,v.x,tol)&&between(p.y,u.y,v.y,tol);
    };
    return on(c,a,b)||on(d,a,b)||on(a,c,d)||on(b,c,d);
}
bool in_triangle(Vec3 p,const std::array<Vec3,3>& tri,double tol)
{
    const Vec3 ab=minus(tri[1],tri[0]),ac=minus(tri[2],tri[0]);
    const Vec3 v=minus(p,tri[0]),normal=product(ab,ac);
    const double size=magnitude(normal);
    if(size<=tol*tol||std::abs(scalar(v,normal))/size>tol)return false;
    const double aa=scalar(ab,ab),bb=scalar(ab,ac),cc=scalar(ac,ac);
    const double denom=aa*cc-bb*bb;
    if(denom<=tol*tol*tol*tol)return false;
    const double u=(cc*scalar(v,ab)-bb*scalar(v,ac))/denom;
    const double w=(aa*scalar(v,ac)-bb*scalar(v,ab))/denom;
    return u>=-tol&&w>=-tol&&u+w<=1+tol;
}
bool bounds_overlap(const Aabb& box,const Aabb& other,double tol)
{
    return box.minimum.x<=other.maximum.x+tol&&other.minimum.x<=box.maximum.x+tol&&
           box.minimum.y<=other.maximum.y+tol&&other.minimum.y<=box.maximum.y+tol&&
           box.minimum.z<=other.maximum.z+tol&&other.minimum.z<=box.maximum.z+tol;
}
Aabb triangle_box(const std::array<Vec3,3>& triangle)
{
    Aabb b{triangle[0],triangle[0]};
    for(auto p:triangle)
    {
        b.minimum.x=std::min(b.minimum.x,p.x);
        b.minimum.y=std::min(b.minimum.y,p.y);
        b.minimum.z=std::min(b.minimum.z,p.z);
        b.maximum.x=std::max(b.maximum.x,p.x);
        b.maximum.y=std::max(b.maximum.y,p.y);
        b.maximum.z=std::max(b.maximum.z,p.z);
    }
    return b;
}
bool triangle_touches_face(const std::array<Vec3,3>& triangle,
                           const FloorPartition::NormalizedFace& face,double tol)
{
    const auto& frame=face.frame;
    const Vec3 a=triangle[0],b=triangle[1],c=triangle[2];
    const Vec3 raw=product(minus(b,a),minus(c,a));
    const double size=magnitude(raw);
    if(size<=tol*tol)return true; // Degenerate membrane is not certifiable.
    const Vec3 normal=times(raw,1.0/size);
    const auto offset=[&](Vec3 p) { return scalar(minus(p,a),normal); };
    const auto signed_face=[&](Vec3 p) {
        return scalar(minus(p,frame.origin),frame.n);
    };
    const auto face_contains=[&](Vec3 p) {
        return FloorPartition::classify_domain(face,frame.project(p),tol)!=Location::Outside;
    };

    // The face and membrane may be exactly coplanar. A single sample cannot
    // prove disjointness; test vertices and EVERY boundary segment including
    // Inner Loops.
    const bool parallel=magnitude(product(normal,frame.n))<=1.0e-9;
    if(parallel)
    {
        if(std::abs(signed_face(a))>tol)return false;
        for(const Vec3 p:triangle)if(face_contains(p))return true;
        const std::array<Vec2,3> projected{{
            frame.project(a),frame.project(b),frame.project(c)
        }};
        const auto inspect=[&](const FloorPartition::NormalizedLoop& ring) {
            for(std::size_t i=0;i<ring.points.size();++i)
            {
                const Vec2 first=ring.points[i],last=ring.points[(i+1)%ring.points.size()];
                if(in_triangle(frame.lift(first),triangle,tol))return true;
                for(std::size_t j=0;j<3;++j)
                    if(segment_touch(first,last,projected[j],projected[(j+1)%3],tol))
                        return true;
            }
            return false;
        };
        if(inspect(face.outer))return true;
        for(const auto& hole:face.holes)if(inspect(hole))return true;
        return false;
    }

    // Exact piecewise-linear surface/triangle intersection. Test boundary
    // edges of both shapes against the other shape's supporting plane, then
    // classify intersection points against the TRUE polygon domains.
    const auto inspect_ring=[&](const FloorPartition::NormalizedLoop& ring) {
        for(std::size_t i=0;i<ring.points.size();++i)
        {
            const Vec3 first=frame.lift(ring.points[i]);
            const Vec3 last=frame.lift(ring.points[(i+1)%ring.points.size()]);
            const double da=offset(first),db=offset(last);
            if((da>tol&&db>tol)||(da< -tol&&db< -tol))continue;
            if(std::abs(da)<=tol&&in_triangle(first,triangle,tol))return true;
            if(std::abs(db)<=tol&&in_triangle(last,triangle,tol))return true;
            if(da*db<0)
            {
                const Vec3 hit=plus(first,times(minus(last,first),da/(da-db)));
                if(in_triangle(hit,triangle,tol))return true;
            }
        }
        return false;
    };
    if(inspect_ring(face.outer))return true;
    for(const auto& hole:face.holes)if(inspect_ring(hole))return true;
    for(std::size_t i=0;i<3;++i)
    {
        const Vec3 first=triangle[i],last=triangle[(i+1)%3];
        const double da=signed_face(first),db=signed_face(last);
        if((da>tol&&db>tol)||(da< -tol&&db< -tol))continue;
        if(std::abs(da)<=tol&&face_contains(first))return true;
        if(std::abs(db)<=tol&&face_contains(last))return true;
        if(da*db<0)
        {
            const Vec3 hit=plus(first,times(minus(last,first),da/(da-db)));
            if(face_contains(hit))return true;
        }
    }
    return false;
}
} // namespace

bool FaceSolid::membrane_clear(const std::vector<std::array<Vec3,3>>& patches,
                               double tolerance) const
{
    if(!valid_||!std::isfinite(tolerance)||tolerance<=0||patches.empty())return false;
    for(const auto& patch:patches)
    {
        const Aabb box=triangle_box(patch);
        std::vector<std::size_t> pending{0};
        while(!pending.empty())
        {
            const std::size_t id=pending.back();
            pending.pop_back();
            const Node& node=nodes_[id];
            if(!bounds_overlap(box,node.box,tolerance))continue;
            if(!node.leaf())
            {
                pending.push_back(node.left);
                pending.push_back(node.right);
                continue;
            }
            for(std::size_t i=node.begin;i<node.begin+node.count;++i)
            {
                const Surface& surface=surfaces_[order_[i]];
                if(!bounds_overlap(box,surface.box,tolerance))continue;
                if(triangle_touches_face(patch,surface.face,tolerance))return false;
            }
        }
    }
    return true;
}
} // namespace IndoorGMLAdjacencyNative
