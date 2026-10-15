#include "floor_reference_loops.h"
#include "floor_face_solid.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <limits>
#include <numeric>
#include <utility>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
namespace
{
constexpr std::size_t MAX_VERTICES=32;
constexpr std::size_t MAX_SEARCH_STEPS=150000;
constexpr std::size_t MAX_CANDIDATES=256;
constexpr std::size_t MAX_CERTIFICATION_ATTEMPTS=1024;
struct P2 { double x,y; };
Vec3 add(Vec3 a,Vec3 b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
Vec3 sub(Vec3 a,Vec3 b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
Vec3 mul(Vec3 a,double k) { return {a.x*k,a.y*k,a.z*k}; }
double dot(Vec3 a,Vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
Vec3 cross(Vec3 a,Vec3 b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
double length(Vec3 a) { return std::sqrt(dot(a,a)); }
double turn(P2 a,P2 b,P2 c) { return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x); }
bool on_segment(P2 p,P2 a,P2 b,double t)
{
    return std::abs(turn(a,b,p))<=t*std::max(1.0,std::hypot(b.x-a.x,b.y-a.y)) &&
        p.x>=std::min(a.x,b.x)-t && p.x<=std::max(a.x,b.x)+t &&
        p.y>=std::min(a.y,b.y)-t && p.y<=std::max(a.y,b.y)+t;
}
bool segments_touch(P2 a,P2 b,P2 c,P2 d,double t)
{
    const double x=turn(a,b,c),y=turn(a,b,d),z=turn(c,d,a),w=turn(c,d,b);
    if (((x>t&&y< -t)||(x< -t&&y>t)) &&
        ((z>t&&w< -t)||(z< -t&&w>t))) return true;
    return (std::abs(x)<=t&&on_segment(c,a,b,t)) ||
        (std::abs(y)<=t&&on_segment(d,a,b,t)) ||
        (std::abs(z)<=t&&on_segment(a,c,d,t)) ||
        (std::abs(w)<=t&&on_segment(b,c,d,t));
}
bool in_polygon(P2 p,const std::vector<P2>& polygon,double t)
{
    bool inside=false;
    for(std::size_t i=0;i<polygon.size();++i)
    {
        const P2 a=polygon[i],b=polygon[(i+1)%polygon.size()];
        if(on_segment(p,a,b,t))return true;
        if((a.y>p.y)!=(b.y>p.y) &&
            p.x<a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y))inside=!inside;
    }
    return inside;
}
struct Membrane
{
    std::vector<std::array<Vec3,3>> triangles;
    std::vector<P2> projected;
    Vec3 origin{},u{},v{},normal{},centroid{};
};
bool triangulate(const std::vector<std::size_t>& cycle,
                 const ReferenceGraphDebug& graph,double tol,Membrane& result)
{
    const std::size_t n=cycle.size();
    if(n<3||n>MAX_VERTICES)return false;
    std::vector<Vec3> points;
    for(const auto i:cycle)points.push_back(graph.nodes[i].point);
    result.origin=points.front();
    Vec3 normal{};
    for(std::size_t i=0;i<n;++i)
        normal=add(normal,cross(sub(points[i],result.origin),
                                sub(points[(i+1)%n],result.origin)));
    const double nl=length(normal);
    const double ul=length(sub(points[1],points[0]));
    if(nl<=tol*tol || ul<=tol)return false;
    result.normal=mul(normal,1.0/nl);
    result.u=mul(sub(points[1],points[0]),1.0/ul);
    result.v=cross(result.normal,result.u);
    if(length(result.v)<0.99)return false;
    for(const Vec3& p:points)
    {
        const Vec3 delta=sub(p,result.origin);
        if(std::abs(dot(delta,result.normal))>tol)return false;
        result.projected.push_back({dot(delta,result.u),dot(delta,result.v)});
    }
    for(std::size_t i=0;i<n;++i)
    {
        if(length(sub(points[i],points[(i+1)%n]))<=tol)return false;
        for(std::size_t j=i+2;j<n;++j)
        {
            if(i==0&&j+1==n)continue;
            if(segments_touch(result.projected[i],result.projected[(i+1)%n],
                              result.projected[j],result.projected[(j+1)%n],tol))
                return false;
        }
    }
    double area=0;
    for(std::size_t i=0;i<n;++i)
        area+=result.projected[i].x*result.projected[(i+1)%n].y-
              result.projected[(i+1)%n].x*result.projected[i].y;
    if(area<=8*tol*tol)return false;
    std::vector<std::size_t> remaining(n);
    std::iota(remaining.begin(),remaining.end(),0);
    Vec3 moment{};
    double total=0;
    auto emit=[&](std::size_t a,std::size_t b,std::size_t c) {
        const std::array<Vec3,3> tri{{points[a],points[b],points[c]}};
        const double weight=0.5*length(cross(sub(points[b],points[a]),sub(points[c],points[a])));
        if(weight<=tol*tol)return false;
        moment=add(moment,mul(add(add(points[a],points[b]),points[c]),weight/3.0));
        total+=weight;
        result.triangles.push_back(tri);
        return true;
    };
    while(remaining.size()>3)
    {
        bool found=false;
        for(std::size_t j=0;j<remaining.size();++j)
        {
            const std::size_t a=remaining[(j+remaining.size()-1)%remaining.size()];
            const std::size_t b=remaining[j],c=remaining[(j+1)%remaining.size()];
            if(turn(result.projected[a],result.projected[b],result.projected[c])<=tol*tol)continue;
            bool occupied=false;
            for(std::size_t other:remaining)
            {
                if(other==a||other==b||other==c)continue;
                const P2 p=result.projected[other];
                if(turn(result.projected[a],result.projected[b],p)>=-tol &&
                   turn(result.projected[b],result.projected[c],p)>=-tol &&
                   turn(result.projected[c],result.projected[a],p)>=-tol)
                { occupied=true;break; }
            }
            if(occupied)continue;
            if(!emit(a,b,c))return false;
            remaining.erase(remaining.begin()+static_cast<std::ptrdiff_t>(j));
            found=true;
            break;
        }
        if(!found)return false;
    }
    if(!emit(remaining[0],remaining[1],remaining[2])||total<=tol*tol)return false;
    result.centroid=mul(moment,1.0/total);
    return true;
}
void certify(const std::vector<std::size_t>& cycle,const FaceSolid& solid,
             ReferenceGraphDebug& graph,
             const std::vector<std::vector<std::size_t>>& adjacent,double tol)
{
    // Internal chords disappear with the certified ring members during graph
    // contraction. They are not a topology barrier; the exact membrane,
    // interior-node, Solid and external-gateway LOS checks below remain the
    // authority for whether the complete ring may be collapsed.
    Membrane mesh;
    if(!triangulate(cycle,graph,tol,mesh))return;
    std::vector<bool> in_cycle(graph.nodes.size(),false);
    for(auto i:cycle)in_cycle[i]=true;
    // The ring must not silently delete another reference center.
    for(std::size_t i=0;i<graph.nodes.size();++i)
    {
        if(in_cycle[i])continue;
        const Vec3 d=sub(graph.nodes[i].point,mesh.origin);
        if(std::abs(dot(d,mesh.normal))<=tol &&
           in_polygon({dot(d,mesh.u),dot(d,mesh.v)},mesh.projected,tol))return;
    }
    // Analytic polygon/Face intersection; no point sampling for Hole detection.
    if(!solid.membrane_clear(mesh.triangles,tol))return;
    for(const auto& tri:mesh.triangles)
    {
        const Vec3 p=mul(add(add(tri[0],tri[1]),tri[2]),1.0/3.0);
        if(!solid.inside(p,tol))return;
    }
    std::vector<std::size_t> boundary;
    for(const auto i:cycle)
        for(auto j:adjacent[i])if(!in_cycle[j])boundary.push_back(j);
    std::sort(boundary.begin(),boundary.end());
    boundary.erase(std::unique(boundary.begin(),boundary.end()),boundary.end());
    std::vector<Vec3> centers;
    if(in_cycle[0])centers.push_back(graph.nodes[0].point);
    else
    {
        centers.push_back(mesh.centroid);
        for(const auto& tri:mesh.triangles)
            centers.push_back(mul(add(add(tri[0],tri[1]),tri[2]),1.0/3.0));
        std::stable_sort(centers.begin(),centers.end(),[&](Vec3 a,Vec3 b) {
            return solid.nearest_distance(a)>solid.nearest_distance(b);
        });
    }
    for(const Vec3 p:centers)
    {
        if(!solid.inside(p,tol))continue;
        const double clearance=solid.nearest_distance(p)-tol;
        if(!std::isfinite(clearance)||clearance<=0)continue;
        bool valid=true;
        for(auto i:cycle)
            if(!in_cycle[0] && !solid.visible(p,graph.nodes[i].point,tol))
            { valid=false;break; }
        if(!valid)continue;
        for(auto i:boundary)
            if(!solid.visible(p,graph.nodes[i].point,tol))
            { valid=false;break; }
        if(!valid)continue;
        ReferenceLoopCollapseCandidate candidate;
        candidate.vertices=cycle;
        candidate.representative=in_cycle[0]?graph.nodes[0]:ReferenceGraphNode{p,clearance};
        candidate.visible_neighbors=boundary;
        graph.loop_candidates.push_back(std::move(candidate));
        return;
    }
}
} // namespace

void certify_before_reference_loops(const FaceSolid& solid,
                                    ReferenceGraphDebug& graph,double tolerance) noexcept
{
    try
    {
        if(!solid.valid()||!std::isfinite(tolerance)||tolerance<=0)return;
        const std::size_t n=graph.nodes.size();
        if(n<3)return;
        std::vector<std::vector<std::size_t>> adj(n);
        for(const auto& edge:graph.edges)
        {
            if(edge.first>=n||edge.second>=n||edge.first==edge.second)continue;
            adj[edge.first].push_back(edge.second);
            adj[edge.second].push_back(edge.first);
        }
        for(auto& neighbors:adj)
        {
            std::sort(neighbors.begin(),neighbors.end());
            neighbors.erase(std::unique(neighbors.begin(),neighbors.end()),neighbors.end());
        }
        std::vector<bool> visited(n,false);
        std::vector<std::size_t> cycle;
        std::size_t steps=0,attempts=0;
        std::size_t target_size=3;
        std::function<void(std::size_t,std::size_t)> walk;
        walk=[&](std::size_t start,std::size_t current)
        {
            if(++steps>MAX_SEARCH_STEPS||attempts>=MAX_CERTIFICATION_ATTEMPTS||
               graph.loop_candidates.size()>=MAX_CANDIDATES)return;
            for(std::size_t next:adj[current])
            {
                // Bound inspected neighbor edges, not just recursive calls.
                // Dense 415+ node graphs must never cause unbounded scans.
                if(++steps>MAX_SEARCH_STEPS)return;
                if(next==start)
                {
                    if(cycle.size()==target_size&&cycle[1]<cycle.back())
                    {
                        ++attempts;
                        certify(cycle,solid,graph,adj,tolerance);
                    }
                    continue;
                }
                if(next<=start||visited[next]||cycle.size()>=target_size)continue;
                visited[next]=true;
                cycle.push_back(next);
                walk(start,next);
                cycle.pop_back();
                visited[next]=false;
                if(steps>MAX_SEARCH_STEPS||attempts>=MAX_CERTIFICATION_ATTEMPTS||
                   graph.loop_candidates.size()>=MAX_CANDIDATES)break;
            }
        };
        // Spend the fixed search/certification budgets on the cheapest and
        // most useful contractions first: every triangle, then every
        // quadrilateral, followed by progressively larger simple rings.
        for(target_size=3;target_size<=MAX_VERTICES;++target_size)
        {
            for(std::size_t start=0;start<n;++start)
            {
                cycle={start};
                visited[start]=true;
                walk(start,start);
                visited[start]=false;
                if(steps>MAX_SEARCH_STEPS||attempts>=MAX_CERTIFICATION_ATTEMPTS||
                   graph.loop_candidates.size()>=MAX_CANDIDATES)break;
            }
            if(steps>MAX_SEARCH_STEPS||attempts>=MAX_CERTIFICATION_ATTEMPTS||
               graph.loop_candidates.size()>=MAX_CANDIDATES)break;
        }
    }
    catch(...)
    {
        // Optional certificate discovery never invalidates a successful State.
        graph.loop_candidates.clear();
    }
}
} // namespace IndoorGMLAdjacencyNative
