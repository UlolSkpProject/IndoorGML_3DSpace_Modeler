#include "floor_polygon_preparation.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <utility>

namespace IndoorGMLAdjacencyNative
{
namespace FloorPartition
{
namespace
{
constexpr double EPSILON = 1.0e-12;
constexpr double RAD_TO_DEGREES = 180.0 / 3.14159265358979323846;

Vec3 subtract(Vec3 a, Vec3 b)
{
    return {a.x-b.x, a.y-b.y, a.z-b.z};
}

Vec3 cross(Vec3 a, Vec3 b)
{
    return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}

double dot(Vec3 a, Vec3 b)
{
    return a.x*b.x+a.y*b.y+a.z*b.z;
}

double norm(Vec3 v)
{
    return std::sqrt(dot(v,v));
}

bool finite(Vec3 v)
{
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

Vec2 subtract(Vec2 a, Vec2 b)
{
    return {a.x-b.x, a.y-b.y};
}

double dot(Vec2 a, Vec2 b)
{
    return a.x*b.x+a.y*b.y;
}

double cross(Vec2 a, Vec2 b)
{
    return a.x*b.y-a.y*b.x;
}

double norm(Vec2 v)
{
    return std::sqrt(dot(v,v));
}

double distance_squared(Vec2 a, Vec2 b)
{
    const Vec2 d=subtract(a,b);
    return dot(d,d);
}

bool less_xy(Vec2 a, Vec2 b)
{
    return a.x<b.x || (a.x==b.x && a.y<b.y);
}

double signed_area(const std::vector<Vec2>& vertices)
{
    // Shift the origin to a nearby vertex to improve large-coordinate
    // robustness. Do not rely on absolute SketchUp world coordinates.
    const Vec2 anchor=vertices.front();
    double twice_area=0.0;
    for (std::size_t i=0;i<vertices.size();++i)
        twice_area+=cross(
            subtract(vertices[i],anchor),
            subtract(vertices[(i+1)%vertices.size()],anchor));
    return 0.5*twice_area;
}

void canonicalize(NormalizedLoop& loop, bool clockwise)
{
    const bool reverse=clockwise ?
        loop.signed_area>0.0 : loop.signed_area<0.0;
    if (reverse)
    {
        std::reverse(loop.points.begin(),loop.points.end());
        std::reverse(loop.source_vertex_indices.begin(),
                     loop.source_vertex_indices.end());
        loop.signed_area=-loop.signed_area;
    }

    std::size_t first=0;
    for (std::size_t i=1;i<loop.points.size();++i)
        if (less_xy(loop.points[i],loop.points[first])) first=i;
    std::rotate(loop.points.begin(),loop.points.begin()+first,loop.points.end());
    std::rotate(loop.source_vertex_indices.begin(),
                loop.source_vertex_indices.begin()+first,
                loop.source_vertex_indices.end());

    loop.bounds.minimum=loop.points.front();
    loop.bounds.maximum=loop.points.front();
    for (const Vec2& point : loop.points)
    {
        loop.bounds.minimum.x=std::min(loop.bounds.minimum.x,point.x);
        loop.bounds.minimum.y=std::min(loop.bounds.minimum.y,point.y);
        loop.bounds.maximum.x=std::max(loop.bounds.maximum.x,point.x);
        loop.bounds.maximum.y=std::max(loop.bounds.maximum.y,point.y);
    }
}

std::optional<Frame> make_frame(Vec3 normal, Vec3 origin)
{
    if (!finite(normal) || !finite(origin)) return std::nullopt;
    const double magnitude=norm(normal);
    if (!std::isfinite(magnitude) || magnitude<=EPSILON)
        return std::nullopt;
    const Vec3 n={normal.x/magnitude,normal.y/magnitude,normal.z/magnitude};
    // Cross with the coordinate axis LEAST parallel to n, giving a
    // stable orthonormal right-handed frame even for vertical faces.
    const double ax=std::abs(n.x),ay=std::abs(n.y),az=std::abs(n.z);
    const Vec3 seed=ax<=ay && ax<=az ? Vec3{1,0,0} :
                    ay<=az ? Vec3{0,1,0} : Vec3{0,0,1};
    const Vec3 across=cross(seed,n);
    const double across_length=norm(across);
    if (!std::isfinite(across_length) || across_length<=EPSILON)
        return std::nullopt;
    const Vec3 u={across.x/across_length,
                  across.y/across_length,
                  across.z/across_length};
    return Frame{origin,u,cross(n,u),n};
}

struct LoopResult
{
    std::optional<NormalizedLoop> loop;
    PreparationError error=PreparationError::None;
};

LoopResult prepare_loop(
    const Frame& frame, const std::vector<Vec3>& input,
    bool hole, std::size_t source_loop_index, double tolerance)
{
    if (input.size()<3)
        return {{},hole ? PreparationError::InvalidInnerLoop :
                        PreparationError::InvalidOuterLoop};

    NormalizedLoop loop;
    loop.hole=hole;
    loop.source_loop_index=source_loop_index;
    for (std::size_t i=0;i<input.size();++i)
    {
        const Vec3& p=input[i];
        if (!finite(p))
            return {{},hole ? PreparationError::InvalidInnerLoop :
                            PreparationError::InvalidOuterLoop};
        if (std::abs(dot(subtract(p,frame.origin),frame.n))>tolerance)
            return {{},PreparationError::NonPlanarLoop};
        const Vec2 projected=frame.project(p);
        if (!std::isfinite(projected.x)||!std::isfinite(projected.y))
            return {{},PreparationError::InvalidOuterLoop};
        if (loop.points.empty() ||
            distance_squared(loop.points.back(),projected)>tolerance*tolerance)
        {
            loop.points.push_back(projected);
            loop.source_vertex_indices.push_back(i);
        }
    }
    if (loop.points.size()>1 &&
        distance_squared(loop.points.front(),loop.points.back())<=
            tolerance*tolerance)
    {
        loop.points.pop_back();
        loop.source_vertex_indices.pop_back();
    }
    if (loop.points.size()<3) return {{},PreparationError::DegenerateLoop};

    loop.signed_area=signed_area(loop.points);
    if (!std::isfinite(loop.signed_area) ||
        std::abs(loop.signed_area)<=tolerance*tolerance)
        return {{},PreparationError::DegenerateLoop};

    canonicalize(loop,hole);
    return {std::move(loop),PreparationError::None};
}

std::optional<Vec2> angular_bisector(
    const NormalizedLoop& loop, std::size_t i, double signed_turn)
{
    const std::size_t size=loop.points.size();
    const Vec2 a=subtract(loop.points[(i+size-1)%size],loop.points[i]);
    const Vec2 b=subtract(loop.points[(i+1)%size],loop.points[i]);
    const double la=norm(a),lb=norm(b);
    if (!(la>EPSILON && lb>EPSILON)) return std::nullopt;
    Vec2 result={a.x/la+b.x/lb,a.y/la+b.y/lb};
    // At a reflex vertex the large (domain-interior) angle is the
    // complement of the minor angle between adjacent edge vectors.
    // Both outer CCW and hole CW use the SAME signed-turn convention.
    if (signed_turn<0.0)
    {
        result.x=-result.x;
        result.y=-result.y;
    }
    const double len=norm(result);
    if (!std::isfinite(len) || len<=EPSILON) return std::nullopt;
    return Vec2{result.x/len,result.y/len};
}

void propose_loop(
    const NormalizedLoop& loop,
    double threshold, double noise,
    std::vector<SplitCandidate>& output)
{
    const std::size_t n=loop.points.size();
    std::vector<double> turns(n);
    for (std::size_t i=0;i<n;++i)
    {
        const Vec2 incoming=subtract(
            loop.points[i],loop.points[(i+n-1)%n]);
        const Vec2 outgoing=subtract(
            loop.points[(i+1)%n],loop.points[i]);
        const double angle=std::atan2(
            cross(incoming,outgoing),dot(incoming,outgoing))
            *RAD_TO_DEGREES;
        turns[i]=std::abs(angle)<=noise ? 0.0 : angle;
    }

    // Two laps: for outer CCW rings (+360 total) the first pass resolves
    // a negative run that straddles the canonical ring seam. For holes
    // (-360 total), deterministic canonical ordering and an independent
    // per-ring accumulator avoid depending on unrelated loops.
    double accumulated=0.0;
    const std::size_t initial_count=output.size();
    for (std::size_t lap=0;lap<2;++lap)
        for (std::size_t i=0;i<n;++i)
        {
            accumulated+=turns[i];
            if (accumulated>=0.0)
            {
                accumulated=0.0;
                continue;
            }
            if (turns[i]>=0.0 || accumulated>-threshold+1.0e-9)
                continue;
            accumulated=0.0;
            if (lap==0) continue;
            const auto direction=angular_bisector(loop,i,turns[i]);
            if (!direction) continue;
            output.push_back({
                loop.hole?LoopKind::Inner:LoopKind::Outer,
                loop.source_loop_index,
                i,loop.source_vertex_indices[i],
                loop.points[i],*direction,
                loop.hole,false,turns[i]
            });
        }

    // Required hole-only fallback: if no accumulated reflex candidate
    // exists, try the FIRST (canonical) inner-loop vertex. Its two rays
    // will be clipped and validated by later phases, not here.
    if (loop.hole && output.size()==initial_count)
    {
        const std::size_t i=0;
        const auto direction=angular_bisector(loop,i,turns[i]);
        if (direction)
            output.push_back({
                LoopKind::Inner,loop.source_loop_index,
                i,loop.source_vertex_indices[i],
                loop.points[i],*direction,true,true,turns[i]
            });
    }
}
} // namespace

Vec2 Frame::project(const Vec3& point) const
{
    const Vec3 d=subtract(point,origin);
    return {dot(d,u),dot(d,v)};
}

Vec3 Frame::lift(const Vec2& point) const
{
    return {origin.x+point.x*u.x+point.y*v.x,
            origin.y+point.x*u.y+point.y*v.y,
            origin.z+point.x*u.z+point.y*v.z};
}

PreparationResult prepare(
    const Vec3& normal,
    const std::vector<Vec3>& outer_loop,
    const std::vector<std::vector<Vec3>>& inner_loops,
    double tolerance
)
{
    if (!std::isfinite(tolerance) || tolerance<=0.0)
        return {{},PreparationError::InvalidTolerance,0};
    if (outer_loop.empty())
        return {{},PreparationError::InvalidOuterLoop,0};
    const auto frame=make_frame(normal,outer_loop.front());
    if (!frame)
        return {{},PreparationError::InvalidNormal,0};
    const LoopResult outer=prepare_loop(
        *frame,outer_loop,false,0,tolerance);
    if (!outer.loop) return {{},outer.error,0};
    NormalizedFace result{*frame,*outer.loop,{}};
    result.holes.reserve(inner_loops.size());
    for (std::size_t i=0;i<inner_loops.size();++i)
    {
        const LoopResult inner=prepare_loop(
            *frame,inner_loops[i],true,i+1,tolerance);
        if (!inner.loop) return {{},inner.error,i+1};
        result.holes.push_back(*inner.loop);
    }
    // Input enumeration order is not geometrically meaningful.
    std::sort(result.holes.begin(),result.holes.end(),
              [](const NormalizedLoop& a,const NormalizedLoop& b) {
                  const Vec2 ap=a.points.front(),bp=b.points.front();
                  if (less_xy(ap,bp)) return true;
                  if (less_xy(bp,ap)) return false;
                  return a.source_loop_index<b.source_loop_index;
              });
    return {std::move(result),PreparationError::None,0};
}

CandidateResult propose_splits(
    const NormalizedFace& face,
    double cumulative_reflex_degrees,
    double angular_noise_degrees
)
{
    CandidateResult result;
    if (!std::isfinite(cumulative_reflex_degrees) ||
        cumulative_reflex_degrees<=0.0 ||
        !std::isfinite(angular_noise_degrees) ||
        angular_noise_degrees<0.0 || angular_noise_degrees>=180.0)
        return result;
    result.valid_settings=true;
    propose_loop(face.outer,cumulative_reflex_degrees,
                 angular_noise_degrees,result.candidates);
    for (const NormalizedLoop& hole:face.holes)
        propose_loop(hole,cumulative_reflex_degrees,
                     angular_noise_degrees,result.candidates);
    return result;
}

} // namespace FloorPartition
} // namespace IndoorGMLAdjacencyNative
