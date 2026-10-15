#include "floor_polygon_reference.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <optional>
#include <queue>
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

struct Segment2 {
    Vec2 first;
    Vec2 second;
};

double cross2(Vec2 a,Vec2 b,Vec2 c)
{
    return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);
}
double squared2(Vec2 a,Vec2 b)
{
    const double x=a.x-b.x,y=a.y-b.y;
    return x*x+y*y;
}
double length2(Vec2 a,Vec2 b)
{
    return std::sqrt(squared2(a,b));
}
double ring_area(const std::vector<Vec2>& ring)
{
    double twice=0.0;
    for (std::size_t i=0;i<ring.size();++i)
    {
        const Vec2 a=ring[i],b=ring[(i+1)%ring.size()];
        twice+=a.x*b.y-a.y*b.x;
    }
    return twice*0.5;
}
double ring_perimeter(const std::vector<Vec2>& ring)
{
    double result=0.0;
    for (std::size_t i=0;i<ring.size();++i)
        result+=length2(ring[i],ring[(i+1)%ring.size()]);
    return result;
}
std::vector<Vec2> ring_in_frame(const PartitionLeaf& leaf,const Frame& frame)
{
    std::vector<Vec2> result;
    result.reserve(leaf.polygon.outer.points.size());
    for (Vec2 point:leaf.polygon.outer.points)
        result.push_back(frame.project(leaf.polygon.frame.lift(point)));
    return result;
}
std::vector<Segment2> ring_edges(const std::vector<Vec2>& ring)
{
    std::vector<Segment2> result;
    result.reserve(ring.size());
    for (std::size_t i=0;i<ring.size();++i)
        result.push_back({ring[i],ring[(i+1)%ring.size()]});
    return result;
}
bool point_on_segment(Vec2 point,const Segment2& segment,double tolerance)
{
    const double segment_length=length2(segment.first,segment.second);
    if (segment_length<=tolerance) return false;
    if (std::abs(cross2(segment.first,segment.second,point))>
        tolerance*segment_length) return false;
    const double dx=segment.second.x-segment.first.x;
    const double dy=segment.second.y-segment.first.y;
    const double t=((point.x-segment.first.x)*dx+
                    (point.y-segment.first.y)*dy)/
                   (segment_length*segment_length);
    return t>=-tolerance/segment_length &&
           t<=1.0+tolerance/segment_length;
}
int boundary_relation(Vec2 point,const Segment2& source,
                      const std::vector<Segment2>& other,double tolerance)
{
    const double sx=source.second.x-source.first.x;
    const double sy=source.second.y-source.first.y;
    for (const Segment2& edge:other)
    {
        if (!point_on_segment(point,edge,tolerance)) continue;
        const double ox=edge.second.x-edge.first.x;
        const double oy=edge.second.y-edge.first.y;
        return sx*ox+sy*oy<0.0 ? -1 : 1;
    }
    return 0;
}

std::optional<std::vector<Segment2>> exposed_segments(
    const std::vector<Segment2>& source,
    const std::vector<Segment2>& other,
    double tolerance,double* shared_length)
{
    std::vector<Segment2> result;
    for (const Segment2& edge:source)
    {
        const double dx=edge.second.x-edge.first.x;
        const double dy=edge.second.y-edge.first.y;
        const double edge_length=std::sqrt(dx*dx+dy*dy);
        if (edge_length<=tolerance) return std::nullopt;
        const double denominator=edge_length*edge_length;
        std::vector<double> parameters{0.0,1.0};
        for (const Segment2& candidate:other)
            for (Vec2 point:{candidate.first,candidate.second})
            {
                if (!point_on_segment(point,edge,tolerance)) continue;
                double t=((point.x-edge.first.x)*dx+
                          (point.y-edge.first.y)*dy)/denominator;
                t=std::max(0.0,std::min(1.0,t));
                parameters.push_back(t);
            }
        std::sort(parameters.begin(),parameters.end());
        parameters.erase(std::unique(parameters.begin(),parameters.end(),
            [=](double a,double b) {
                return std::abs(a-b)*edge_length<=tolerance;
            }),parameters.end());
        for (std::size_t i=0;i+1<parameters.size();++i)
        {
            const double first=parameters[i],last=parameters[i+1];
            if ((last-first)*edge_length<=tolerance) continue;
            const Vec2 a{edge.first.x+dx*first,edge.first.y+dy*first};
            const Vec2 b{edge.first.x+dx*last,edge.first.y+dy*last};
            const Vec2 midpoint{(a.x+b.x)*0.5,(a.y+b.y)*0.5};
            const int relation=boundary_relation(midpoint,{a,b},other,tolerance);
            if (relation>0) return std::nullopt; // overlapping material
            if (relation<0)
            {
                if (shared_length) *shared_length+=length2(a,b);
                continue;
            }
            result.push_back({a,b});
        }
    }
    return result;
}

std::optional<std::vector<Vec2>> stitch_single_cycle(
    const std::vector<Segment2>& segments,double tolerance)
{
    if (segments.size()<3) return std::nullopt;
    std::vector<Vec2> vertices;
    const auto vertex_id=[&](Vec2 point) {
        for (std::size_t i=0;i<vertices.size();++i)
            if (squared2(vertices[i],point)<=tolerance*tolerance) return i;
        vertices.push_back(point);
        return vertices.size()-1;
    };
    struct Directed { std::size_t first=0,second=0; };
    std::vector<Directed> edges;
    for (const Segment2& segment:segments)
    {
        const std::size_t first=vertex_id(segment.first);
        const std::size_t second=vertex_id(segment.second);
        if (first==second) return std::nullopt;
        edges.push_back({first,second});
    }
    std::vector<std::vector<std::size_t>> outgoing(vertices.size());
    std::vector<std::size_t> incoming(vertices.size(),0);
    for (std::size_t i=0;i<edges.size();++i)
    {
        outgoing[edges[i].first].push_back(i);
        ++incoming[edges[i].second];
    }
    for (std::size_t i=0;i<vertices.size();++i)
        if (outgoing[i].size()!=1 || incoming[i]!=1) return std::nullopt;
    std::size_t start=0;
    for (std::size_t i=1;i<vertices.size();++i)
        if (std::tie(vertices[i].x,vertices[i].y)<
            std::tie(vertices[start].x,vertices[start].y)) start=i;
    std::vector<bool> used(edges.size(),false);
    std::vector<Vec2> ring;
    std::size_t current=start;
    do
    {
        ring.push_back(vertices[current]);
        const std::size_t edge=outgoing[current].front();
        if (used[edge]) return std::nullopt;
        used[edge]=true;
        current=edges[edge].second;
        if (ring.size()>edges.size()) return std::nullopt;
    } while (current!=start);
    if (ring.size()!=edges.size() ||
        std::find(used.begin(),used.end(),false)!=used.end())
        return std::nullopt;

    bool changed=true;
    while (changed && ring.size()>3)
    {
        changed=false;
        for (std::size_t i=0;i<ring.size();++i)
        {
            const Vec2 a=ring[(i+ring.size()-1)%ring.size()];
            const Vec2 b=ring[i];
            const Vec2 c=ring[(i+1)%ring.size()];
            const double scale=length2(a,b)+length2(b,c);
            const double forward=(b.x-a.x)*(c.x-b.x)+
                                 (b.y-a.y)*(c.y-b.y);
            if (std::abs(cross2(a,b,c))<=tolerance*scale &&
                forward>=-tolerance*scale)
            {
                ring.erase(ring.begin()+i);
                changed=true;
                break;
            }
        }
    }
    return ring.size()>=3 ? std::optional<std::vector<Vec2>>(ring) : std::nullopt;
}

bool convex_ccw(const std::vector<Vec2>& ring,double tolerance)
{
    if (ring.size()<3 || ring_area(ring)<=tolerance*tolerance) return false;
    for (std::size_t i=0;i<ring.size();++i)
    {
        const Vec2 a=ring[(i+ring.size()-1)%ring.size()];
        const Vec2 b=ring[i],c=ring[(i+1)%ring.size()];
        const double scale=length2(a,b)+length2(b,c);
        if (cross2(a,b,c)<-tolerance*scale) return false;
    }
    return true;
}

std::optional<PartitionLeaf> merge_pair(
    const PartitionLeaf& first,const PartitionLeaf& second,double tolerance)
{
    if (!first.polygon.holes.empty() || !second.polygon.holes.empty())
        return std::nullopt;
    const Frame& frame=first.polygon.frame;
    const Frame& other=second.polygon.frame;
    // Face provenance is not a geometric barrier: accept different SketchUp
    // Floor Faces when their real 3D boundaries share one coplanar domain.
    // Check the ORIGINAL second-face vertices against the first plane,
    // rather than projecting onto the second face and lifting back (which
    // cannot detect a tilted/noncoplanar neighbour).
    const double normal_alignment=dot(frame.n,other.n);
    for (Vec2 point:second.polygon.outer.points)
    {
        const Vec3 world=other.lift(point);
        if (std::abs(dot(sub(world,frame.origin),frame.n))>tolerance)
            return std::nullopt;
    }
    const std::vector<Vec2> a=ring_in_frame(first,frame);
    std::vector<Vec2> b=ring_in_frame(second,frame);
    // A face's winding may be reversed even when the material domain
    // is coplanar. Canonicalize both boundaries in the chosen 2D frame.
    if (normal_alignment<0.0) std::reverse(b.begin(),b.end());
    const auto bounds=[](const std::vector<Vec2>& ring) {
        Bounds2 result{ring.front(),ring.front()};
        for (Vec2 point:ring)
        {
            result.minimum.x=std::min(result.minimum.x,point.x);
            result.minimum.y=std::min(result.minimum.y,point.y);
            result.maximum.x=std::max(result.maximum.x,point.x);
            result.maximum.y=std::max(result.maximum.y,point.y);
        }
        return result;
    };
    if (a.empty() || b.empty()) return std::nullopt;
    const Bounds2 a_bounds=bounds(a),b_bounds=bounds(b);
    if (a_bounds.maximum.x<b_bounds.minimum.x-tolerance ||
        b_bounds.maximum.x<a_bounds.minimum.x-tolerance ||
        a_bounds.maximum.y<b_bounds.minimum.y-tolerance ||
        b_bounds.maximum.y<a_bounds.minimum.y-tolerance)
        return std::nullopt;
    const auto a_edges=ring_edges(a),b_edges=ring_edges(b);
    double shared=0.0;
    const auto exposed_a=exposed_segments(a_edges,b_edges,tolerance,&shared);
    const auto exposed_b=exposed_segments(b_edges,a_edges,tolerance,nullptr);
    if (!exposed_a || !exposed_b || shared<=tolerance) return std::nullopt;
    std::vector<Segment2> exposed=*exposed_a;
    exposed.insert(exposed.end(),exposed_b->begin(),exposed_b->end());
    const auto ring=stitch_single_cycle(exposed,tolerance);
    if (!ring || !convex_ccw(*ring,tolerance)) return std::nullopt;
    const double expected=std::abs(ring_area(a))+std::abs(ring_area(b));
    const double actual=ring_area(*ring);
    const double area_tolerance=std::max(
        tolerance*tolerance*16.0,
        tolerance*(ring_perimeter(a)+ring_perimeter(b)+ring_perimeter(*ring))*2.0);
    if (!std::isfinite(actual) ||
        std::abs(actual-expected)>area_tolerance) return std::nullopt;
    std::vector<Vec3> world;
    world.reserve(ring->size());
    for (Vec2 point:*ring) world.push_back(frame.lift(point));
    const auto prepared=prepare(first.polygon.plane,world,{},tolerance);
    if (!prepared.face || !prepared.face->holes.empty()) return std::nullopt;
    return PartitionLeaf{
        std::min(first.source_face_id,second.source_face_id),
        std::min(first.depth,second.depth),std::move(*prepared.face)
    };
}

std::vector<Vec3> world_signature(const PartitionLeaf& leaf)
{
    std::vector<Vec3> points;
    for (Vec2 point:leaf.polygon.outer.points)
        points.push_back(leaf.polygon.frame.lift(point));
    if (points.empty()) return points;
    const auto less=[](Vec3 a,Vec3 b) {
        return std::tie(a.x,a.y,a.z)<std::tie(b.x,b.y,b.z);
    };
    const auto minimum=std::min_element(points.begin(),points.end(),less);
    std::rotate(points.begin(),minimum,points.end());
    return points;
}
bool signature_less(const PartitionLeaf& a,const PartitionLeaf& b)
{
    if (a.source_face_id!=b.source_face_id)
        return a.source_face_id<b.source_face_id;
    const auto first=world_signature(a),second=world_signature(b);
    const auto less=[](Vec3 x,Vec3 y) {
        return std::tie(x.x,x.y,x.z)<std::tie(y.x,y.y,y.z);
    };
    if (std::lexicographical_compare(
            first.begin(),first.end(),second.begin(),second.end(),less)) return true;
    if (std::lexicographical_compare(
            second.begin(),second.end(),first.begin(),first.end(),less)) return false;
    return a.depth<b.depth;
}

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

CoarsenedPartitions merge_convex_partitions(
    const std::vector<PartitionLeaf>& completed,double tolerance,
    const MergeAcceptance& accept)
{
    struct Item {
        PartitionLeaf leaf;
        std::vector<std::size_t> members;
        bool alive=true;
    };
    CoarsenedPartitions output;
    std::vector<Item> items;
    items.reserve(completed.size());
    for (std::size_t i=0;i<completed.size();++i)
        items.push_back({completed[i],{i},true});
    const auto sort_items=[](const Item& a,const Item& b) {
        if (signature_less(a.leaf,b.leaf)) return true;
        if (signature_less(b.leaf,a.leaf)) return false;
        return a.members<b.members;
    };
    std::sort(items.begin(),items.end(),sort_items);
    if (std::isfinite(tolerance) && tolerance>0.0)
    {
        struct Candidate {
            std::size_t first=0,second=0;
            PartitionLeaf merged;
            double area=0.0;
            std::vector<std::size_t> members;
        };
        const auto better=[](const Candidate& a,const Candidate& b) {
            if (a.area!=b.area) return a.area>b.area;
            if (signature_less(a.merged,b.merged)) return true;
            if (signature_less(b.merged,a.merged)) return false;
            return a.members<b.members;
        };
        const auto worse=[&](const Candidate& a,const Candidate& b) {
            return better(b,a);
        };
        std::priority_queue<Candidate,std::vector<Candidate>,decltype(worse)>
            candidates(worse);
        const auto enqueue=[&](std::size_t i,std::size_t j) {
            if (i==j || !items[i].alive || !items[j].alive) return;
            if (j<i) std::swap(i,j);
            auto merged=merge_pair(items[i].leaf,items[j].leaf,tolerance);
            if (!merged) return;
            std::vector<std::size_t> members=items[i].members;
            members.insert(members.end(),items[j].members.begin(),items[j].members.end());
            std::sort(members.begin(),members.end());
            const double area=std::abs(merged->polygon.outer.signed_area);
            candidates.push({i,j,std::move(*merged),area,std::move(members)});
        };
        for (std::size_t i=0;i<items.size();++i)
            for (std::size_t j=i+1;j<items.size();++j) enqueue(i,j);
        while (!candidates.empty())
        {
            Candidate selected=candidates.top();
            candidates.pop();
            if (!items[selected.first].alive || !items[selected.second].alive)
                continue;
            if (accept)
            {
                bool safe=false;
                try { safe=accept(selected.merged,selected.members); }
                catch (...) { safe=false; } // Optional safety check fails closed.
                if (!safe) continue;
            }
            items[selected.first].alive=false;
            items[selected.second].alive=false;
            const std::size_t merged_index=items.size();
            items.push_back({
                std::move(selected.merged),std::move(selected.members),true
            });
            for (std::size_t i=0;i<merged_index;++i)
                if (items[i].alive) enqueue(i,merged_index);
            ++output.accepted_merges;
        }
    }
    items.erase(std::remove_if(items.begin(),items.end(),
        [](const Item& item) { return !item.alive; }),items.end());
    std::sort(items.begin(),items.end(),sort_items);
    output.leaves.reserve(items.size());
    output.source_leaf_indices.reserve(items.size());
    for (Item& item:items)
    {
        output.leaves.push_back(std::move(item.leaf));
        output.source_leaf_indices.push_back(std::move(item.members));
    }
    return output;
}

std::vector<PartitionLeaf> coarsen_with_safe_fallback(
    const std::vector<PartitionLeaf>& completed,double tolerance,
    const MergeAcceptance& accept)
{
    // Keep previously accepted maximal convex unions unchanged: checking
    // each smaller pair first can discard a valid larger union.
    CoarsenedPartitions proposed=merge_convex_partitions(completed,tolerance);
    if(proposed.accepted_merges==0) return completed;
    if(!accept) return proposed.leaves;

    std::vector<std::size_t> order(proposed.leaves.size());
    for(std::size_t i=0;i<order.size();++i)order[i]=i;
    std::sort(order.begin(),order.end(),[&](std::size_t a,std::size_t b) {
        return proposed.source_leaf_indices[a].front()<
               proposed.source_leaf_indices[b].front();
    });

    std::vector<PartitionLeaf> result;
    // The safety callback always expects indices in the ORIGINAL completed
    // batch, even after groups are restored, merged across source Faces,
    // or contracted repeatedly.
    std::vector<std::vector<std::size_t>> provenance;
    bool kept_merge=false;
    bool restored_group=false;
    for(std::size_t i:order)
    {
        const auto& members=proposed.source_leaf_indices[i];
        bool safe=members.size()==1;
        if(!safe)
        {
            try { safe=accept(proposed.leaves[i],members); }
            catch (...) { safe=false; }
        }
        if(safe)
        {
            kept_merge=kept_merge || members.size()>1;
            result.push_back(std::move(proposed.leaves[i]));
            provenance.push_back(members);
            continue;
        }

        restored_group=true;
        // A rejected maximal union can contain safe smaller unions.
        // Every pair must pass the SAME Native reference/LOS requirements.
        std::vector<PartitionLeaf> group;
        group.reserve(members.size());
        for(std::size_t j:members)group.push_back(completed[j]);
        CoarsenedPartitions partial=merge_convex_partitions(
            group,tolerance,
            [&](const PartitionLeaf& candidate,
                const std::vector<std::size_t>& local_members) {
                std::vector<std::size_t> original_members;
                original_members.reserve(local_members.size());
                for(std::size_t j:local_members)
                    original_members.push_back(members[j]);
                return accept(candidate,original_members);
            });
        if(partial.accepted_merges==0)
        {
            // Exact previous rollback when no smaller safe pair exists.
            for(std::size_t j:members)
            {
                result.push_back(completed[j]);
                provenance.push_back({j});
            }
            continue;
        }
        kept_merge=true;
        std::vector<std::size_t> local_order(partial.leaves.size());
        for(std::size_t j=0;j<local_order.size();++j)local_order[j]=j;
        std::sort(local_order.begin(),local_order.end(),
                  [&](std::size_t a,std::size_t b) {
            return partial.source_leaf_indices[a].front()<
                   partial.source_leaf_indices[b].front();
        });
        for(std::size_t j:local_order)
        {
            result.push_back(std::move(partial.leaves[j]));
            std::vector<std::size_t> original_members;
            for(std::size_t index:partial.source_leaf_indices[j])
                original_members.push_back(members[index]);
            provenance.push_back(std::move(original_members));
        }
    }

    // After recovery, a previously separate group may now have a convex
    // shared-edge neighbour. Reinspect ALL currently active polygons;
    // merge_convex_partitions re-enqueues the new polygon against every
    // surviving neighbour, and this outer loop reaches a fixed point.
    // Every committed merge decreases the node count, so it terminates.
    if(restored_group)
    {
        while(result.size()>1)
        {
            CoarsenedPartitions next=merge_convex_partitions(
                result,tolerance,
                [&](const PartitionLeaf& candidate,
                    const std::vector<std::size_t>& indices) {
                    std::vector<std::size_t> originals;
                    for(std::size_t index:indices)
                        originals.insert(originals.end(),
                                         provenance[index].begin(),
                                         provenance[index].end());
                    std::sort(originals.begin(),originals.end());
                    return accept(candidate,originals);
                });
            if(next.accepted_merges==0) break;
            kept_merge=true;
            std::vector<std::vector<std::size_t>> next_provenance;
            next_provenance.reserve(next.leaves.size());
            for(const auto& group:next.source_leaf_indices)
            {
                std::vector<std::size_t> originals;
                for(std::size_t index:group)
                    originals.insert(originals.end(),
                                     provenance[index].begin(),
                                     provenance[index].end());
                std::sort(originals.begin(),originals.end());
                next_provenance.push_back(std::move(originals));
            }
            result=std::move(next.leaves);
            provenance=std::move(next_provenance);
        }
    }
    return kept_merge ? result : completed;
}

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
