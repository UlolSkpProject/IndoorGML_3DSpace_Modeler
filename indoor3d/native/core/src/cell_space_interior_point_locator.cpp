#include "cell_space_interior_point_locator.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <set>
#include <numeric>
#include <optional>
#include <queue>
#include <utility>
#include <vector>

namespace
{
using namespace IndoorGMLAdjacencyNative;

constexpr double EPSILON = 1.0e-12;
constexpr std::size_t BVH_LEAF_TRIANGLES = 6;
constexpr std::size_t MAX_SEARCH_NODES = 200000;
// Legacy triangle-based geometry helpers for non-Room/Stair State and tests.
// A Face is Floor only if its normalized outward normal has Z <= -0.6.
// Inclined floors are accepted only when they satisfy that same criterion.
constexpr double ROOM_FLOOR_MIN_NEGATIVE_NORMAL_Z = 0.6;
// Use the SAME signed-turn accumulator as wall Corner discovery.
// A sequence of small negative (reflex) turns must reach 30 degrees
// before it forces a Floor-region partition; convex turns offset the run.
constexpr double ROOM_FLOOR_CUMULATIVE_REFLEX_DEGREES = 30.0;
constexpr double ROOM_FLOOR_TURN_NOISE_DEGREES = 0.25;
// SketchUp/native coordinates are inches; +1000 mm in world Z.
constexpr double ROOM_REFERENCE_FLOOR_OFFSET = 1000.0 / 25.4;
// Protect the Native V7 reference/debug serialization size bound.
constexpr std::size_t MAX_ROOM_REFERENCE_POINTS = 4096;
constexpr std::size_t MAX_ROOM_REFERENCE_DEBUG_POINTS =
    MAX_ROOM_REFERENCE_POINTS * 3;

double elapsed_seconds(std::chrono::steady_clock::time_point started_at)
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - started_at).count();
}

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 subtract(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 multiply(const Vec3& v, double s) { return {v.x * s, v.y * s, v.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
Vec3 cross(const Vec3& a, const Vec3& b)
{
    return {
        a.y*b.z - a.z*b.y,
        a.z*b.x - a.x*b.z,
        a.x*b.y - a.y*b.x
    };
}
double length_squared(const Vec3& v) { return dot(v, v); }
double length(const Vec3& v) { return std::sqrt(length_squared(v)); }

Vec3 normalize(Vec3 v)
{
    const double l = length(v);
    if (l <= EPSILON) return {1.0, 0.0, 0.0};
    return multiply(v, 1.0 / l);
}

Aabb empty_aabb()
{
    const double inf = std::numeric_limits<double>::infinity();
    return {{inf, inf, inf}, {-inf, -inf, -inf}};
}

void expand(Aabb& box, const Vec3& p)
{
    box.minimum.x = std::min(box.minimum.x, p.x);
    box.minimum.y = std::min(box.minimum.y, p.y);
    box.minimum.z = std::min(box.minimum.z, p.z);
    box.maximum.x = std::max(box.maximum.x, p.x);
    box.maximum.y = std::max(box.maximum.y, p.y);
    box.maximum.z = std::max(box.maximum.z, p.z);
}

void expand(Aabb& box, const Aabb& other)
{
    expand(box, other.minimum);
    expand(box, other.maximum);
}

Vec3 aabb_center(const Aabb& box)
{
    return multiply(add(box.minimum, box.maximum), 0.5);
}

Vec3 aabb_half_extent(const Aabb& box)
{
    return multiply(subtract(box.maximum, box.minimum), 0.5);
}

double max_component(const Vec3& v)
{
    return std::max(v.x, std::max(v.y, v.z));
}

Aabb triangle_bounds(const Triangle& t)
{
    Aabb box = empty_aabb();
    for (const Vec3& p : t.points) expand(box, p);
    return box;
}

Vec3 triangle_centroid(const Triangle& t)
{
    return multiply(add(add(t.points[0], t.points[1]), t.points[2]), 1.0 / 3.0);
}

bool ray_triangle(
    const Vec3& origin,
    const Vec3& direction,
    const Triangle& triangle,
    double tolerance,
    double& distance
)
{
    const Vec3 edge1 = subtract(triangle.points[1], triangle.points[0]);
    const Vec3 edge2 = subtract(triangle.points[2], triangle.points[0]);
    const Vec3 pvec = cross(direction, edge2);
    const double determinant = dot(edge1, pvec);
    if (std::abs(determinant) <= EPSILON) return false;

    const double inverse = 1.0 / determinant;
    const Vec3 tvec = subtract(origin, triangle.points[0]);
    const double u = dot(tvec, pvec) * inverse;
    const double bary_epsilon = 1.0e-10;
    if (u < -bary_epsilon || u > 1.0 + bary_epsilon) return false;

    const Vec3 qvec = cross(tvec, edge1);
    const double v = dot(direction, qvec) * inverse;
    if (v < -bary_epsilon || u + v > 1.0 + bary_epsilon) return false;

    const double t = dot(edge2, qvec) * inverse;
    if (t <= tolerance) return false;
    distance = t;
    return true;
}

double point_triangle_distance_squared(const Vec3& p, const Triangle& triangle)
{
    const Vec3 a = triangle.points[0];
    const Vec3 b = triangle.points[1];
    const Vec3 c = triangle.points[2];
    const Vec3 ab = subtract(b, a);
    const Vec3 ac = subtract(c, a);
    const Vec3 ap = subtract(p, a);
    const double d1 = dot(ab, ap);
    const double d2 = dot(ac, ap);
    if (d1 <= 0.0 && d2 <= 0.0) return length_squared(ap);

    const Vec3 bp = subtract(p, b);
    const double d3 = dot(ab, bp);
    const double d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) return length_squared(bp);

    const double vc = d1*d4 - d3*d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0)
    {
        const double v = d1 / (d1 - d3);
        return length_squared(subtract(p, add(a, multiply(ab, v))));
    }

    const Vec3 cp = subtract(p, c);
    const double d5 = dot(ab, cp);
    const double d6 = dot(ac, cp);
    if (d6 >= 0.0 && d5 <= d6) return length_squared(cp);

    const double vb = d5*d2 - d1*d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0)
    {
        const double w = d2 / (d2 - d6);
        return length_squared(subtract(p, add(a, multiply(ac, w))));
    }

    const double va = d3*d6 - d5*d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0)
    {
        const Vec3 bc = subtract(c, b);
        const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return length_squared(subtract(p, add(b, multiply(bc, w))));
    }

    const double denominator = 1.0 / (va + vb + vc);
    const double v = vb * denominator;
    const double w = vc * denominator;
    const Vec3 projected = add(a, add(multiply(ab, v), multiply(ac, w)));
    return length_squared(subtract(p, projected));
}

double point_aabb_distance_squared(const Vec3& p, const Aabb& box)
{
    double result = 0.0;
    const std::array<double,3> value{p.x,p.y,p.z};
    const std::array<double,3> minimum{box.minimum.x,box.minimum.y,box.minimum.z};
    const std::array<double,3> maximum{box.maximum.x,box.maximum.y,box.maximum.z};
    for (std::size_t axis=0; axis<3; ++axis)
    {
        double delta = 0.0;
        if (value[axis] < minimum[axis]) delta = minimum[axis] - value[axis];
        else if (value[axis] > maximum[axis]) delta = value[axis] - maximum[axis];
        result += delta * delta;
    }
    return result;
}

bool ray_aabb(const Vec3& origin, const Vec3& direction, const Aabb& box)
{
    double tmin = 0.0;
    double tmax = std::numeric_limits<double>::infinity();
    const std::array<double,3> o{origin.x,origin.y,origin.z};
    const std::array<double,3> d{direction.x,direction.y,direction.z};
    const std::array<double,3> mn{box.minimum.x,box.minimum.y,box.minimum.z};
    const std::array<double,3> mx{box.maximum.x,box.maximum.y,box.maximum.z};

    for (std::size_t axis=0; axis<3; ++axis)
    {
        if (std::abs(d[axis]) <= EPSILON)
        {
            if (o[axis] < mn[axis] || o[axis] > mx[axis]) return false;
            continue;
        }
        double first = (mn[axis] - o[axis]) / d[axis];
        double second = (mx[axis] - o[axis]) / d[axis];
        if (first > second) std::swap(first, second);
        tmin = std::max(tmin, first);
        tmax = std::min(tmax, second);
        if (tmax < tmin) return false;
    }
    return tmax > 0.0;
}

std::vector<const Triangle*> triangle_pointers(const CellData& cell)
{
    std::vector<const Triangle*> triangles;
    for (const FaceData& face : cell.faces)
    {
        for (const Triangle& triangle : face.triangles)
        {
            const Vec3 edge1 = subtract(triangle.points[1], triangle.points[0]);
            const Vec3 edge2 = subtract(triangle.points[2], triangle.points[0]);
            if (length_squared(cross(edge1, edge2)) <= EPSILON * EPSILON)
                continue;
            triangles.push_back(&triangle);
        }
    }
    return triangles;
}

class TriangleBvh
{
public:
    explicit TriangleBvh(std::vector<const Triangle*> triangles)
        : triangles_(std::move(triangles))
    {
        indices_.resize(triangles_.size());
        std::iota(indices_.begin(), indices_.end(), 0u);
        if (!indices_.empty()) build_node(0, indices_.size());
    }

    bool empty() const { return triangles_.empty(); }

    std::size_t ray_intersection_count(
        const Vec3& origin,
        const Vec3& direction,
        double tolerance
    ) const
    {
        std::vector<double> distances;
        if (nodes_.empty()) return 0;
        collect_ray(0, origin, direction, tolerance, distances);
        if (distances.empty()) return 0;
        std::sort(distances.begin(), distances.end());
        std::size_t write = 1;
        double last = distances.front();
        for (std::size_t read=1; read<distances.size(); ++read)
        {
            if (std::abs(distances[read] - last) <= tolerance) continue;
            distances[write++] = distances[read];
            last = distances[read];
        }
        return write;
    }

    // First positive boundary hit along a 3D ray. Also used for
    // conservative whole-segment LOS (including thin interior walls).
    double first_ray_hit(const Vec3& origin, const Vec3& direction,
                         double tolerance) const
    {
        std::vector<double> distances;
        if (nodes_.empty()) return std::numeric_limits<double>::infinity();
        collect_ray(0, origin, direction, tolerance, distances);
        double result = std::numeric_limits<double>::infinity();
        for (double distance : distances)
            if (distance > tolerance) result = std::min(result, distance);
        return result;
    }

    double nearest_distance(const Vec3& point) const
    {
        if (nodes_.empty()) return std::numeric_limits<double>::infinity();
        double best_squared = std::numeric_limits<double>::infinity();
        nearest(0, point, best_squared);
        return std::sqrt(best_squared);
    }

private:
    struct Node
    {
        Aabb bounds;
        std::uint32_t left = 0;
        std::uint32_t right = 0;
        std::uint32_t first = 0;
        std::uint32_t count = 0;
    };

    std::uint32_t build_node(std::size_t first, std::size_t count)
    {
        Node node;
        node.bounds = empty_aabb();
        Aabb centroid_bounds = empty_aabb();
        for (std::size_t i=first; i<first+count; ++i)
        {
            expand(node.bounds, triangle_bounds(*triangles_[indices_[i]]));
            expand(centroid_bounds, triangle_centroid(*triangles_[indices_[i]]));
        }

        const std::uint32_t node_index = static_cast<std::uint32_t>(nodes_.size());
        nodes_.push_back(node);

        if (count <= BVH_LEAF_TRIANGLES)
        {
            nodes_[node_index].first = static_cast<std::uint32_t>(first);
            nodes_[node_index].count = static_cast<std::uint32_t>(count);
            return node_index;
        }

        const Vec3 extent = subtract(centroid_bounds.maximum, centroid_bounds.minimum);
        int axis = 0;
        if (extent.y > extent.x) axis = 1;
        if ((axis == 0 ? extent.x : extent.y) < extent.z) axis = 2;

        const std::size_t middle = first + count / 2;
        std::nth_element(
            indices_.begin()+static_cast<std::ptrdiff_t>(first),
            indices_.begin()+static_cast<std::ptrdiff_t>(middle),
            indices_.begin()+static_cast<std::ptrdiff_t>(first+count),
            [&](std::uint32_t a, std::uint32_t b) {
                const Vec3 ca = triangle_centroid(*triangles_[a]);
                const Vec3 cb = triangle_centroid(*triangles_[b]);
                if (axis == 0) return ca.x < cb.x;
                if (axis == 1) return ca.y < cb.y;
                return ca.z < cb.z;
            }
        );

        const std::uint32_t left = build_node(first, middle-first);
        const std::uint32_t right = build_node(middle, first+count-middle);
        nodes_[node_index].left = left;
        nodes_[node_index].right = right;
        return node_index;
    }

    void collect_ray(
        std::uint32_t node_index,
        const Vec3& origin,
        const Vec3& direction,
        double tolerance,
        std::vector<double>& distances
    ) const
    {
        const Node& node = nodes_[node_index];
        if (!ray_aabb(origin, direction, node.bounds)) return;
        if (node.count > 0)
        {
            for (std::size_t i=node.first; i<node.first+node.count; ++i)
            {
                double distance = 0.0;
                if (ray_triangle(origin, direction, *triangles_[indices_[i]], tolerance, distance))
                    distances.push_back(distance);
            }
            return;
        }
        collect_ray(node.left, origin, direction, tolerance, distances);
        collect_ray(node.right, origin, direction, tolerance, distances);
    }

    void nearest(std::uint32_t node_index, const Vec3& point, double& best_squared) const
    {
        const Node& node = nodes_[node_index];
        if (point_aabb_distance_squared(point, node.bounds) >= best_squared) return;
        if (node.count > 0)
        {
            for (std::size_t i=node.first; i<node.first+node.count; ++i)
            {
                best_squared = std::min(
                    best_squared,
                    point_triangle_distance_squared(point, *triangles_[indices_[i]])
                );
            }
            return;
        }

        const double left_distance = point_aabb_distance_squared(point, nodes_[node.left].bounds);
        const double right_distance = point_aabb_distance_squared(point, nodes_[node.right].bounds);
        if (left_distance < right_distance)
        {
            nearest(node.left, point, best_squared);
            nearest(node.right, point, best_squared);
        }
        else
        {
            nearest(node.right, point, best_squared);
            nearest(node.left, point, best_squared);
        }
    }

    std::vector<const Triangle*> triangles_;
    std::vector<std::uint32_t> indices_;
    std::vector<Node> nodes_;
};

const std::array<Vec3,3>& ray_directions()
{
    static const std::array<Vec3,3> directions{
        normalize({1.0, 0.371, 0.113}),
        normalize({0.271, 1.0, 0.619}),
        normalize({0.433, 0.197, 1.0})
    };
    return directions;
}

std::size_t direct_ray_count(
    const std::vector<const Triangle*>& triangles,
    const Vec3& point,
    const Vec3& direction,
    double tolerance
)
{
    std::vector<double> distances;
    for (const Triangle* triangle : triangles)
    {
        double distance = 0.0;
        if (ray_triangle(point, direction, *triangle, tolerance, distance))
            distances.push_back(distance);
    }
    if (distances.empty()) return 0;
    std::sort(distances.begin(), distances.end());
    std::size_t write = 1;
    double last = distances.front();
    for (std::size_t read=1; read<distances.size(); ++read)
    {
        if (std::abs(distances[read]-last) <= tolerance) continue;
        distances[write++] = distances[read];
        last = distances[read];
    }
    return write;
}

bool direct_inside(
    const std::vector<const Triangle*>& triangles,
    const Vec3& point,
    double tolerance
)
{
    int votes = 0;
    for (const Vec3& direction : ray_directions())
    {
        if ((direct_ray_count(triangles, point, direction, tolerance) % 2) == 1) ++votes;
    }
    return votes >= 2;
}

double direct_nearest_distance(
    const std::vector<const Triangle*>& triangles,
    const Vec3& point
)
{
    double best_squared = std::numeric_limits<double>::infinity();
    for (const Triangle* triangle : triangles)
        best_squared = std::min(best_squared, point_triangle_distance_squared(point, *triangle));
    return std::sqrt(best_squared);
}

bool bvh_inside(const TriangleBvh& bvh, const Vec3& point, double tolerance)
{
    int votes = 0;
    for (const Vec3& direction : ray_directions())
    {
        if ((bvh.ray_intersection_count(point, direction, tolerance) % 2) == 1) ++votes;
    }
    return votes >= 2;
}

std::optional<Vec3> volume_centroid(const CellData& cell)
{
    const Vec3 reference = aabb_center(cell.bounds);
    Vec3 weighted{0.0,0.0,0.0};
    double total_volume = 0.0;

    for (const FaceData& face : cell.faces)
    {
        for (const Triangle& source : face.triangles)
        {
            Vec3 a = source.points[0];
            Vec3 b = source.points[1];
            Vec3 c = source.points[2];
            if (dot(cross(subtract(b,a), subtract(c,a)), face.normal) < 0.0)
                std::swap(b,c);

            const Vec3 ar = subtract(a,reference);
            const Vec3 br = subtract(b,reference);
            const Vec3 cr = subtract(c,reference);
            const double volume = dot(ar,cross(br,cr)) / 6.0;
            const Vec3 tetra_centroid = multiply(add(add(ar,br),cr), 0.25);
            weighted = add(weighted, multiply(tetra_centroid, volume));
            total_volume += volume;
        }
    }

    const Vec3 extent = subtract(cell.bounds.maximum, cell.bounds.minimum);
    const double scale = std::max(1.0, std::abs(extent.x*extent.y*extent.z));
    if (std::abs(total_volume) <= scale * 1.0e-12) return std::nullopt;
    return add(reference, multiply(weighted, 1.0 / total_volume));
}

struct SearchBox
{
    Vec3 center;
    Vec3 half;
    double signed_distance = -std::numeric_limits<double>::infinity();
    double upper_bound = -std::numeric_limits<double>::infinity();
};

struct SearchBoxLess
{
    bool operator()(const SearchBox& a, const SearchBox& b) const
    {
        return a.upper_bound < b.upper_bound;
    }
};

SearchBox evaluate_box(
    const TriangleBvh& bvh,
    const Vec3& center,
    const Vec3& half,
    double tolerance
)
{
    const double distance = bvh.nearest_distance(center);
    const bool inside = bvh_inside(bvh, center, tolerance);
    const double signed_distance = inside ? distance : -distance;
    const double radius = length(half);
    return {center, half, signed_distance, signed_distance + radius};
}

std::optional<Vec3> spatial_search(
    const CellData& cell,
    const TriangleBvh& bvh,
    double tolerance
)
{
    const bool fixed_z = cell.has_fixed_z();
    Vec3 center = aabb_center(cell.bounds);
    Vec3 half = aabb_half_extent(cell.bounds);
    if (fixed_z)
    {
        if (cell.fixed_z < cell.bounds.minimum.z - tolerance ||
            cell.fixed_z > cell.bounds.maximum.z + tolerance)
            return std::nullopt;
        center.z = cell.fixed_z;
        half.z = 0.0;
    }

    const double diagonal = length(aabb_half_extent(cell.bounds)) * 2.0;
    const double precision = std::max(tolerance * 4.0, diagonal / 4096.0);

    std::priority_queue<SearchBox,std::vector<SearchBox>,SearchBoxLess> queue;
    queue.push(evaluate_box(bvh, center, half, tolerance));

    std::optional<Vec3> best;
    double best_distance = tolerance;
    std::size_t processed = 0;

    while (!queue.empty() && processed < MAX_SEARCH_NODES)
    {
        const SearchBox current = queue.top();
        queue.pop();
        ++processed;

        if (current.upper_bound <= best_distance + precision) continue;
        if (current.signed_distance > best_distance)
        {
            best = current.center;
            best_distance = current.signed_distance;
        }

        const double cell_size = fixed_z
            ? std::max(current.half.x, current.half.y)
            : max_component(current.half);
        if (cell_size <= precision) continue;

        const Vec3 child_half{
            current.half.x * 0.5,
            current.half.y * 0.5,
            fixed_z ? 0.0 : current.half.z * 0.5
        };

        const int z_count = fixed_z ? 1 : 2;
        for (int ix=-1; ix<=1; ix+=2)
        {
            for (int iy=-1; iy<=1; iy+=2)
            {
                for (int iz_index=0; iz_index<z_count; ++iz_index)
                {
                    const int iz = fixed_z ? 0 : (iz_index == 0 ? -1 : 1);
                    Vec3 child_center{
                        current.center.x + static_cast<double>(ix)*child_half.x,
                        current.center.y + static_cast<double>(iy)*child_half.y,
                        fixed_z ? cell.fixed_z :
                            current.center.z + static_cast<double>(iz)*child_half.z
                    };
                    SearchBox child = evaluate_box(bvh, child_center, child_half, tolerance);
                    if (child.upper_bound > best_distance + precision)
                        queue.push(child);
                    if (child.signed_distance > best_distance)
                    {
                        best = child.center;
                        best_distance = child.signed_distance;
                    }
                }
            }
        }
    }
    return best;
}
} // namespace

namespace IndoorGMLAdjacencyNative
{
std::optional<Vec3> find_state_point(
    const CellData& cell,
    double tolerance,
    StateSearchMetrics* metrics
)
{
    if (!(tolerance > 0.0) || !std::isfinite(tolerance))
        return std::nullopt;

    const std::vector<const Triangle*> triangles = triangle_pointers(cell);
    if (triangles.empty()) return std::nullopt;

    const std::optional<Vec3> volume = volume_centroid(cell);
    if (volume)
    {
        Vec3 candidate = *volume;
        if (cell.has_fixed_z()) candidate.z = cell.fixed_z;
        if (direct_inside(triangles, candidate, tolerance) &&
            direct_nearest_distance(triangles, candidate) > tolerance)
        {
            if (metrics) metrics->volume_centroid_succeeded = true;
            return candidate;
        }
    }

    const auto build_started = std::chrono::steady_clock::now();
    TriangleBvh bvh(triangles);
    if (metrics)
    {
        metrics->used_bvh = true;
        metrics->bvh_build_duration = elapsed_seconds(build_started);
    }
    if (bvh.empty()) return std::nullopt;

    const auto search_started = std::chrono::steady_clock::now();
    const std::optional<Vec3> result = spatial_search(cell, bvh, tolerance);
    if (metrics) metrics->bvh_search_duration = elapsed_seconds(search_started);
    return result;
}

namespace
{

bool clear_path(
    const TriangleBvh& bvh,
    const Vec3& first,
    const Vec3& second,
    double tolerance
)
{
    const Vec3 segment = subtract(second, first);
    const double length3 = length(segment);
    if (!std::isfinite(length3) || length3 <= tolerance * 2.0)
        return false;
    // Unlike sparse BVH midpoint tests, exact segment/triangle hits detect
    // thin walls, floors and holes that a long 3D chord could cross.
    if (bvh.first_ray_hit(first, multiply(segment, 1.0 / length3),
                          tolerance) < length3 - tolerance)
        return false;
    for (const double t : {0.125, 0.25, 0.5, 0.75, 0.875})
    {
        const Vec3 candidate = add(first, multiply(segment, t));
        if (!bvh_inside(bvh, candidate, tolerance) ||
            bvh.nearest_distance(candidate) <= tolerance)
            return false;
    }
    return true;
}

} // namespace

// Floor-region experiment: use the SketchUp-triangulated Floor surface as
// a constrained mesh. Greedily merge only edge-adjacent, exactly coplanar
// triangles whose UNION has one simple, convex boundary. A hole always
// leaves multiple boundary rings and can never pass this validation.
// Adjacent coplanar SketchUp Faces can be merged too, provided their mesh
// edges match. Limited concavity is permitted by the signed-turn budget; The original geometry and its triangles are never modified.
namespace
{
using FloorVertexKey = std::array<std::int64_t, 3>;
using FloorEdgeKey = std::pair<FloorVertexKey, FloorVertexKey>;

struct FloorTriangle
{
    std::array<Vec3, 3> vertices;
    std::array<FloorVertexKey, 3> keys;
    Vec3 outward_normal;
    Vec3 centroid;
    double area = 0.0;
    bool mergeable = false;
};

struct FloorRegion
{
    std::vector<std::size_t> triangles;
    Vec3 centroid;
    double area = 0.0;
    bool active = true;
};

std::optional<FloorVertexKey> floor_vertex_key(
    const Vec3& p, double epsilon
)
{
    const auto quantize = [epsilon](double coordinate)
        -> std::optional<std::int64_t>
    {
        const double scaled = coordinate / epsilon;
        if (!std::isfinite(scaled) ||
            std::abs(scaled) > static_cast<double>(
                std::numeric_limits<std::int64_t>::max() / 4))
            return std::nullopt;
        return static_cast<std::int64_t>(std::llround(scaled));
    };
    const auto x = quantize(p.x);
    const auto y = quantize(p.y);
    const auto z = quantize(p.z);
    if (!x || !y || !z) return std::nullopt;
    return FloorVertexKey{*x, *y, *z};
}

FloorEdgeKey floor_edge_key(
    const FloorVertexKey& a, const FloorVertexKey& b
)
{
    return a < b ? FloorEdgeKey{a, b} : FloorEdgeKey{b, a};
}

// Validate the ACTUAL triangle union, not its convex hull. In particular:
//  - every boundary vertex has degree two;
//  - exactly one boundary ring must consume every boundary edge;
//  - the cumulative negative (reflex) turn stays below 30 degrees;
//  - polygon area must match the sum of original triangle areas;
//  - every triangle must be coplanar and have matching outward normals.
// Permits a gently concave region; it is NOT a strictly convexity check.
// An unmerged single triangle never needs this reconstruction.
bool cumulative_turn_floor_union(
    const std::vector<std::size_t>& members,
    const std::vector<FloorTriangle>& triangles,
    double planar_tolerance,
    double tolerance
)
{
    if (members.size() < 2) return false;
    const FloorTriangle& first = triangles[members.front()];
    if (!first.mergeable) return false;
    const Vec3 reference_normal = first.outward_normal;
    const Vec3 plane_origin = first.vertices[0];
    double original_area = 0.0;

    std::map<FloorEdgeKey, std::size_t> edge_counts;
    std::map<FloorVertexKey, Vec3> vertex_positions;
    for (const std::size_t id : members)
    {
        const FloorTriangle& t = triangles[id];
        if (!t.mergeable ||
            dot(t.outward_normal, reference_normal) < 1.0 - 1.0e-9)
            return false;
        original_area += t.area;
        for (std::size_t v=0; v<3; ++v)
        {
            if (std::abs(dot(subtract(t.vertices[v], plane_origin),
                             reference_normal)) > planar_tolerance)
                return false;
            vertex_positions.emplace(t.keys[v], t.vertices[v]);
            const FloorEdgeKey key = floor_edge_key(
                t.keys[v], t.keys[(v+1)%3]);
            const std::size_t count = ++edge_counts[key];
            if (count > 2) return false;
        }
    }
    std::map<FloorVertexKey, std::vector<FloorVertexKey>> boundary;
    std::size_t edge_count = 0;
    for (const auto& entry : edge_counts)
    {
        if (entry.second != 1) continue;
        const FloorVertexKey& a = entry.first.first;
        const FloorVertexKey& b = entry.first.second;
        boundary[a].push_back(b);
        boundary[b].push_back(a);
        ++edge_count;
    }
    if (edge_count < 3 || boundary.size() != edge_count)
        return false;
    for (const auto& vertex : boundary)
        if (vertex.second.size() != 2 ||
            vertex.second[0] == vertex.second[1])
            return false;

    // Walk just ONE boundary ring. A Hole produces a second ring and
    // fails the all-edges-consumed check below.
    std::vector<FloorVertexKey> ring;
    ring.reserve(edge_count);
    const FloorVertexKey start = boundary.begin()->first;
    FloorVertexKey current = start;
    std::optional<FloorVertexKey> previous;
    for (std::size_t step=0; step<edge_count; ++step)
    {
        ring.push_back(current);
        const auto& adjacent = boundary.at(current);
        const FloorVertexKey next =
            previous && adjacent[0] == *previous ?
                adjacent[1] : adjacent[0];
        previous = current;
        current = next;
        if (current == start && step+1 < edge_count)
            return false;
    }
    if (current != start || ring.size() != boundary.size())
        return false;

    // Signed area and convexity are measured in the common 3D Floor plane.
    double twice_area = 0.0;
    for (std::size_t i=0; i<ring.size(); ++i)
    {
        const Vec3 a = subtract(vertex_positions.at(ring[i]), plane_origin);
        const Vec3 b = subtract(
            vertex_positions.at(ring[(i+1)%ring.size()]), plane_origin);
        twice_area += dot(cross(a,b), reference_normal);
    }
    const double signed_area = 0.5 * twice_area;
    const double area_tolerance =
        std::max(original_area * 1.0e-7, tolerance * tolerance);
    if (std::abs(signed_area) <= area_tolerance ||
        std::abs(std::abs(signed_area)-original_area) > area_tolerance)
        return false;
    const double orientation = signed_area > 0.0 ? 1.0 : -1.0;

    // Calculate each external XY/plane signed turn in DEGREES. Unlike
    // an immediate any-reflex veto, a single small notch does not force
    // an extra Floor region. Adjacent small reflex angles accumulate,
    // while convex turns offset the running negative amount.
    std::vector<double> turns;
    turns.reserve(ring.size());
    constexpr double RAD_TO_DEGREES = 180.0 / 3.14159265358979323846;
    for (std::size_t i=0; i<ring.size(); ++i)
    {
        const Vec3& a = vertex_positions.at(ring[i]);
        const Vec3& b = vertex_positions.at(ring[(i+1)%ring.size()]);
        const Vec3& c = vertex_positions.at(ring[(i+2)%ring.size()]);
        const Vec3 ab = subtract(b,a);
        const Vec3 bc = subtract(c,b);
        const double len_ab = length(ab);
        const double len_bc = length(bc);
        if (len_ab <= planar_tolerance || len_bc <= planar_tolerance)
            return false;
        const double signed_cross =
            orientation * dot(cross(ab,bc), reference_normal);
        const double signed_dot = dot(ab,bc);
        const double degrees =
            std::atan2(signed_cross,signed_dot) * RAD_TO_DEGREES;
        if (!std::isfinite(degrees)) return false;
        turns.push_back(
            std::abs(degrees) <= ROOM_FLOOR_TURN_NOISE_DEGREES ?
                0.0 : degrees
        );
    }

    // A polygon ring has no canonical first Vertex. Traverse twice to
    // preserve accumulated negative turns across the arbitrary ring seam.
    // Its total signed turn is +360 degrees, so a reset occurs during
    // a full lap and the next lap observes the cyclic steady state.
    RoomSignedTurnAccumulator accumulation(
        ROOM_FLOOR_CUMULATIVE_REFLEX_DEGREES);
    for (std::size_t lap=0; lap<2; ++lap)
        for (double degrees : turns)
            if (accumulation.advance(degrees))
                return false;

    // A mildly concave polygon's area centroid can fall OUTSIDE its real
    // triangle union. Never merge in that case: the original pieces
    // remain intact and their centroids are tested independently.
    Vec3 area_moment{0,0,0};
    for (const std::size_t id : members)
        area_moment = add(area_moment,
            multiply(triangles[id].centroid,triangles[id].area));
    const Vec3 area_centroid =
        multiply(area_moment,1.0/original_area);

    const auto inside_triangle = [&](const FloorTriangle& t) {
        const Vec3 e0 = subtract(t.vertices[1],t.vertices[0]);
        const Vec3 e1 = subtract(t.vertices[2],t.vertices[0]);
        const Vec3 p = subtract(area_centroid,t.vertices[0]);
        const double d00=dot(e0,e0);
        const double d01=dot(e0,e1);
        const double d11=dot(e1,e1);
        const double d20=dot(p,e0);
        const double d21=dot(p,e1);
        const double denom=d00*d11-d01*d01;
        if (denom <= EPSILON) return false;
        const double u=(d11*d20-d01*d21)/denom;
        const double v=(d00*d21-d01*d20)/denom;
        constexpr double BARYCENTRIC_EPSILON = 1.0e-9;
        return u >= -BARYCENTRIC_EPSILON &&
               v >= -BARYCENTRIC_EPSILON &&
               u+v <= 1.0 + BARYCENTRIC_EPSILON;
    };
    for (const std::size_t id : members)
        if (inside_triangle(triangles[id])) return true;
    return false;
}

std::vector<FloorRegion> merge_floor_triangles_by_cumulative_turn(
    const std::vector<FloorTriangle>& triangles,
    const std::vector<std::vector<std::size_t>>& face_groups,
    double planar_tolerance,
    double tolerance
)
{
    std::vector<FloorRegion> regions;
    regions.reserve(triangles.size() * 2);
    std::vector<std::size_t> owners(triangles.size());

    // Recognize a hole-free SketchUp Face with cumulative reflex <30deg
    // AS A WHOLE before pairwise merges. A single weakly concave notch
    // is not enough to create redundant Ref Points.
    for (const auto& group : face_groups)
    {
        if (group.empty()) continue;
        if (group.size() > 1 &&
            cumulative_turn_floor_union(group, triangles,
                               planar_tolerance, tolerance))
        {
            double area = 0.0;
            Vec3 moment{0,0,0};
            for (std::size_t id : group)
            {
                const FloorTriangle& t = triangles[id];
                area += t.area;
                moment = add(moment, multiply(t.centroid, t.area));
            }
            const std::size_t region_id = regions.size();
            regions.push_back({group, multiply(moment, 1.0/area), area, true});
            for (std::size_t id : group) owners[id] = region_id;
        }
        else
        {
            // Strongly concave, Hole-bearing or nonmanifold Face: preserve
            // original triangles until safe region-level merging.
            for (std::size_t id : group)
            {
                owners[id] = regions.size();
                regions.push_back({{id}, triangles[id].centroid,
                                   triangles[id].area, true});
            }
        }
    }

    // Candidate adjacency is based ONLY on true shared triangle edges.
    // A boundary of a Hole has no opposite triangle, thus no candidate pair.
    std::map<FloorEdgeKey, std::vector<std::size_t>> edge_owners;
    for (std::size_t i=0; i<triangles.size(); ++i)
    {
        const FloorTriangle& t = triangles[i];
        if (!t.mergeable) continue;
        for (std::size_t j=0; j<3; ++j)
            edge_owners[floor_edge_key(
                t.keys[j], t.keys[(j+1)%3])].push_back(owners[i]);
    }
    std::vector<std::set<std::size_t>> adjacency(regions.size());
    std::queue<std::pair<std::size_t,std::size_t>> pending;
    for (const auto& entry : edge_owners)
    {
        const auto& owners = entry.second;
        // Non-manifold edges are not safe for region merging.
        if (owners.size() != 2 || owners[0] == owners[1])
            continue;
        const std::size_t a = std::min(owners[0], owners[1]);
        const std::size_t b = std::max(owners[0], owners[1]);
        if (adjacency[a].insert(b).second)
        {
            adjacency[b].insert(a);
            pending.push({a,b});
        }
    }

    // Greedy cumulative-turn partition; failed merges preserve BOTH old regions.
    // When either region grows, its new union is rechecked from scratch.
    while (!pending.empty())
    {
        const auto [a,b] = pending.front();
        pending.pop();
        if (!regions[a].active || !regions[b].active ||
            !adjacency[a].count(b))
            continue;
        const FloorRegion& ra = regions[a];
        const FloorRegion& rb = regions[b];
        std::vector<std::size_t> combined = ra.triangles;
        combined.insert(combined.end(), rb.triangles.begin(),
                        rb.triangles.end());
        if (!cumulative_turn_floor_union(combined, triangles,
                                planar_tolerance, tolerance))
            continue;

        const double total_area = ra.area + rb.area;
        const Vec3 weighted = multiply(add(
            multiply(ra.centroid, ra.area),
            multiply(rb.centroid, rb.area)), 1.0 / total_area);
        const std::size_t merged_id = regions.size();
        regions.push_back({std::move(combined), weighted, total_area, true});
        adjacency.emplace_back();

        // Copy neighbors BEFORE rewiring; the just-created region is
        // allowed to grow with either constituent's former neighbors.
        std::set<std::size_t> next = adjacency[a];
        next.insert(adjacency[b].begin(), adjacency[b].end());
        next.erase(a);
        next.erase(b);
        regions[a].active = false;
        regions[b].active = false;
        for (const std::size_t other : next)
        {
            adjacency[other].erase(a);
            adjacency[other].erase(b);
            if (!regions[other].active) continue;
            adjacency[merged_id].insert(other);
            adjacency[other].insert(merged_id);
            pending.push({std::min(merged_id,other),
                          std::max(merged_id,other)});
        }
        adjacency[a].clear();
        adjacency[b].clear();
    }
    return regions;
}

// A Stair Reference anchor is the midpoint of an edge shared by
// TWO FINAL partition polygons. Mesh edges internal to one final polygon
// must never generate an anchor.
struct StairSharedSegment
{
    FloorVertexKey first;
    FloorVertexKey last;
};

// Return one midpoint per maximal straight shared-edge chain, rather than
// one per underlying SketchUp triangulation fragment. Junctions and corners
// deliberately terminate a chain. A nonmanifold edge (>2 owners) is ignored.
std::vector<Vec3> floor_partition_shared_edge_midpoints(
    const std::vector<FloorTriangle>& triangles,
    const std::vector<FloorRegion>& regions,
    double tolerance
)
{
    std::vector<std::size_t> region_of(triangles.size(),regions.size());
    for (std::size_t r=0;r<regions.size();++r)
    {
        if (!regions[r].active) continue;
        for (const std::size_t t : regions[r].triangles)
            region_of[t]=r;
    }

    std::map<FloorEdgeKey,std::vector<std::size_t>> owners;
    std::map<FloorVertexKey,Vec3> positions;
    for (std::size_t t=0;t<triangles.size();++t)
    {
        const FloorTriangle& tri=triangles[t];
        if (!tri.mergeable || region_of[t]>=regions.size()) continue;
        for (std::size_t j=0;j<3;++j)
        {
            positions.emplace(tri.keys[j],tri.vertices[j]);
            owners[floor_edge_key(tri.keys[j],
                    tri.keys[(j+1)%3])].push_back(t);
        }
    }

    using RegionPair = std::pair<std::size_t,std::size_t>;
    std::map<RegionPair,std::vector<StairSharedSegment>> shared;
    for (const auto& entry : owners)
    {
        const auto& t=entry.second;
        if (t.size()!=2 || t[0]==t[1]) continue;
        const std::size_t a=region_of[t[0]],b=region_of[t[1]];
        if (a==b || a>=regions.size() || b>=regions.size()) continue;
        shared[std::minmax(a,b)].push_back(
            {entry.first.first,entry.first.second});
    }

    std::vector<Vec3> centers;
    for (const auto& entry : shared)
    {
        const auto& segments=entry.second;
        std::map<FloorVertexKey,std::vector<std::size_t>> endpoint_edges;
        for (std::size_t i=0;i<segments.size();++i)
        {
            endpoint_edges[segments[i].first].push_back(i);
            endpoint_edges[segments[i].last].push_back(i);
        }
        std::vector<bool> consumed(segments.size(),false);
        for (std::size_t seed=0;seed<segments.size();++seed)
        {
            if (consumed[seed]) continue;
            consumed[seed]=true;
            FloorVertexKey first=segments[seed].first;
            FloorVertexKey last=segments[seed].last;
            const Vec3 axis=subtract(positions.at(last),positions.at(first));
            const double axis_length=length(axis);
            if (axis_length<=tolerance) continue;
            const Vec3 origin=positions.at(first);

            const auto extend=[&](FloorVertexKey& endpoint)
            {
                for (;;)
                {
                    const auto it=endpoint_edges.find(endpoint);
                    // A T-junction, loop, or a corner with more than
                    // two edges is not a continuation of a straight Edge.
                    if (it==endpoint_edges.end() ||
                        it->second.size()!=2) break;
                    std::size_t next=segments.size();
                    for (const std::size_t candidate : it->second)
                        if (!consumed[candidate]) next=candidate;
                    if (next==segments.size()) break;
                    const auto& e=segments[next];
                    const FloorVertexKey other=
                        e.first==endpoint ? e.last : e.first;
                    const Vec3 offset=subtract(positions.at(other),origin);
                    if (length(cross(offset,axis)) >
                        tolerance*axis_length) break;
                    consumed[next]=true;
                    endpoint=other;
                }
            };
            extend(first);
            extend(last);
            Vec3 midpoint=multiply(
                add(positions.at(first),positions.at(last)),0.5);
            if (!std::isfinite(midpoint.x) ||
                !std::isfinite(midpoint.y) ||
                !std::isfinite(midpoint.z)) continue;
            bool duplicate=false;
            for (const Vec3& prior : centers)
                if (length_squared(subtract(prior,midpoint))<=
                    tolerance*tolerance)
                {
                    duplicate=true;
                    break;
                }
            if (!duplicate) centers.push_back(midpoint);
        }
    }
    std::sort(centers.begin(),centers.end(),
              [](const Vec3& a,const Vec3& b) {
                  if (a.x!=b.x) return a.x<b.x;
                  if (a.y!=b.y) return a.y<b.y;
                  return a.z<b.z;
              });
    return centers;
}

} // namespace

// Shared BEFORE seed policy for BOTH Room and Stair:
// (1) area-weighted centroid of each final Floor polygon;
// (2) midpoint of each shared straight boundary between distinct final
//     polygons (never the internal triangulation edges).
// Both candidate types retain +1000 mm WORLD-Z and BVH Solid checks.
// If a region centroid is invalid, retain the existing triangle fallback
// rather than silently losing previously valid interior candidates.
std::vector<ReferencePoint> find_reference_points(
    const CellData& cell,
    double tolerance
)
{
    if (!(tolerance > 0.0) || !std::isfinite(tolerance)) return {};

    const std::vector<const Triangle*> solid_triangles = triangle_pointers(cell);
    if (solid_triangles.empty()) return {};
    TriangleBvh bvh(solid_triangles);
    if (bvh.empty()) return {};

    const double span = std::max({
        cell.bounds.maximum.x - cell.bounds.minimum.x,
        cell.bounds.maximum.y - cell.bounds.minimum.y,
        cell.bounds.maximum.z - cell.bounds.minimum.z
    });
    const double edge_tolerance = std::max({
        tolerance * 0.05, span * 1.0e-10, 1.0e-8
    });
    const double planar_tolerance = std::max(tolerance * 0.05, 1.0e-8);
    std::vector<FloorTriangle> floor_triangles;
    std::vector<std::vector<std::size_t>> face_groups;
    for (const FaceData& face : cell.faces)
    {
        const double normal_length = length(face.normal);
        if (!std::isfinite(normal_length) || normal_length <= EPSILON ||
            face.normal.z > -ROOM_FLOOR_MIN_NEGATIVE_NORMAL_Z * normal_length)
            continue;
        const Vec3 unit_normal = multiply(face.normal, 1.0/normal_length);
        face_groups.emplace_back();
        for (const Triangle& triangle : face.triangles)
        {
            const Vec3 ab = subtract(triangle.points[1], triangle.points[0]);
            const Vec3 ac = subtract(triangle.points[2], triangle.points[0]);
            const double area = 0.5 * length(cross(ab,ac));
            if (!std::isfinite(area) || area <= EPSILON) continue;
            const Vec3 centroid = multiply(add(add(
                triangle.points[0], triangle.points[1]),
                triangle.points[2]), 1.0/3.0);
            FloorTriangle candidate;
            candidate.vertices = triangle.points;
            candidate.outward_normal = unit_normal;
            candidate.centroid = centroid;
            candidate.area = area;
            candidate.mergeable = true;
            for (std::size_t i=0; i<3; ++i)
            {
                const auto key = floor_vertex_key(
                    triangle.points[i], edge_tolerance);
                if (!key)
                {
                    candidate.mergeable = false;
                    break;
                }
                candidate.keys[i] = *key;
            }
            if (candidate.mergeable &&
                (candidate.keys[0] == candidate.keys[1] ||
                 candidate.keys[1] == candidate.keys[2] ||
                 candidate.keys[2] == candidate.keys[0]))
                candidate.mergeable = false;
            face_groups.back().push_back(floor_triangles.size());
            floor_triangles.push_back(std::move(candidate));
        }
    }
    if (floor_triangles.empty()) return {};

    const std::vector<FloorRegion> regions = merge_floor_triangles_by_cumulative_turn(
        floor_triangles, face_groups, planar_tolerance, tolerance);
    std::vector<std::size_t> survivors;
    for (std::size_t i=0; i<regions.size(); ++i)
        if (regions[i].active) survivors.push_back(i);
    // Deterministic order independent of the order of greedy merges.
    std::sort(survivors.begin(), survivors.end(),
        [&](std::size_t a, std::size_t b) {
            return *std::min_element(regions[a].triangles.begin(),
                                      regions[a].triangles.end()) <
                   *std::min_element(regions[b].triangles.begin(),
                                      regions[b].triangles.end());
        });

    std::vector<ReferencePoint> points;
    points.reserve(std::min<std::size_t>(
        floor_triangles.size() * 2, MAX_ROOM_REFERENCE_DEBUG_POINTS));
    std::size_t accepted = 0;
    const auto add_region_point = [&](Vec3 point) -> bool
    {
        point.z += ROOM_REFERENCE_FLOOR_OFFSET;
        if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
            !std::isfinite(point.z) ||
            !bvh_inside(bvh, point, tolerance) ||
            bvh.nearest_distance(point) <= tolerance)
            return false;
        points.push_back({point, ReferencePointKind::Face});
        points.push_back({point, ReferencePointKind::Final});
        ++accepted;
        return true;
    };

    // Room and Stair share the exact same region-centroid path.
    for (const std::size_t region_id : survivors)
    {
        if (accepted >= MAX_ROOM_REFERENCE_POINTS) break;
        const FloorRegion& region = regions[region_id];
        if (add_region_point(region.centroid)) continue;
        // No successful original triangle is sacrificed by a newly
        // invalid merged-region centroid (ceiling/slab overhang etc.).
        if (region.triangles.size() <= 1) continue;
        for (const std::size_t triangle_id : region.triangles)
        {
            if (accepted >= MAX_ROOM_REFERENCE_POINTS) break;
            add_region_point(floor_triangles[triangle_id].centroid);
        }
    }

    // Add shared-edge midpoint candidates for BOTH categories after the
    // polygon centers. A single-region Floor has no shared seam.
    if (accepted < MAX_ROOM_REFERENCE_POINTS)
    {
        const std::vector<Vec3> midpoints =
            floor_partition_shared_edge_midpoints(
                floor_triangles, regions, edge_tolerance);
        for (const Vec3& midpoint : midpoints)
        {
            if (accepted >= MAX_ROOM_REFERENCE_POINTS) break;
            add_region_point(midpoint);
        }
    }
    return points;
}

// Graph stage is unchanged: Final markers are the accepted Floor-region
// centroid/shared-boundary midpoint seeds. Sphere overlap and exact 3D LOS
// determine BEFORE edges.
std::vector<bool> validate_room_reference_segments(
    const CellData& cell,
    const std::vector<std::pair<Vec3, Vec3>>& segments,
    double tolerance
)
{
    std::vector<bool> visible(segments.size(), false);
    if (cell.category != CellSpaceCategory::Room ||
        !std::isfinite(tolerance) || tolerance <= 0.0 || segments.empty())
        return visible;
    const std::vector<const Triangle*> triangles = triangle_pointers(cell);
    if (triangles.empty()) return visible;
    TriangleBvh bvh(triangles);
    if (bvh.empty()) return visible;

    for (std::size_t index=0; index<segments.size(); ++index)
    {
        const Vec3& a = segments[index].first;
        const Vec3& b = segments[index].second;
        if (!std::isfinite(a.x) || !std::isfinite(a.y) || !std::isfinite(a.z) ||
            !std::isfinite(b.x) || !std::isfinite(b.y) || !std::isfinite(b.z) ||
            length_squared(subtract(a, b)) <= tolerance * tolerance)
            continue;
        if (!bvh_inside(bvh, a, tolerance) ||
            !bvh_inside(bvh, b, tolerance) ||
            bvh.nearest_distance(a) <= tolerance ||
            bvh.nearest_distance(b) <= tolerance ||
            !clear_path(bvh, a, b, tolerance))
            continue;
        visible[index] = true;
    }
    return visible;
}

// Conservative 3D loop membrane verification. A graph Loop bounds a
// UNIQUE planar polygon only when all its vertices are coplanar. We never
// invent a spanning membrane for warped rings. A candidate mesh must not
// intersect ANY Solid boundary triangle (including cavity/Hole side walls),
// and its interior must lie in the actual CellSpace volume.
namespace
{
struct LoopPoint2 { double x = 0.0, y = 0.0; };

double loop_cross_2d(const LoopPoint2& a, const LoopPoint2& b,
                     const LoopPoint2& c)
{
    return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);
}

bool point_on_loop_segment(const LoopPoint2& p, const LoopPoint2& a,
                           const LoopPoint2& b, double epsilon)
{
    return std::abs(loop_cross_2d(a,b,p)) <=
        epsilon * std::max(1.0,std::hypot(b.x-a.x,b.y-a.y)) &&
        p.x >= std::min(a.x,b.x)-epsilon &&
        p.x <= std::max(a.x,b.x)+epsilon &&
        p.y >= std::min(a.y,b.y)-epsilon &&
        p.y <= std::max(a.y,b.y)+epsilon;
}

bool loop_segments_touch(const LoopPoint2& a, const LoopPoint2& b,
                         const LoopPoint2& c, const LoopPoint2& d,
                         double epsilon)
{
    const double x=loop_cross_2d(a,b,c);
    const double y=loop_cross_2d(a,b,d);
    const double z=loop_cross_2d(c,d,a);
    const double w=loop_cross_2d(c,d,b);
    if ((x>epsilon && y < -epsilon || x < -epsilon && y > epsilon) &&
        (z>epsilon && w < -epsilon || z < -epsilon && w > epsilon))
        return true;
    return (std::abs(x)<=epsilon && point_on_loop_segment(c,a,b,epsilon)) ||
           (std::abs(y)<=epsilon && point_on_loop_segment(d,a,b,epsilon)) ||
           (std::abs(z)<=epsilon && point_on_loop_segment(a,c,d,epsilon)) ||
           (std::abs(w)<=epsilon && point_on_loop_segment(b,c,d,epsilon));
}

bool triangle_contains_point_3d(const Triangle& triangle,
                                 const Vec3& p, double epsilon)
{
    const Vec3 a=triangle.points[0], ab=subtract(triangle.points[1],a),
               ac=subtract(triangle.points[2],a), ap=subtract(p,a);
    const double aa=dot(ab,ab), bb=dot(ab,ac), cc=dot(ac,ac);
    const double denom=aa*cc-bb*bb;
    if (denom<=EPSILON) return false;
    const double u=(cc*dot(ap,ab)-bb*dot(ap,ac))/denom;
    const double v=(aa*dot(ap,ac)-bb*dot(ap,ab))/denom;
    return u>=-epsilon && v>=-epsilon && u+v<=1.0+epsilon;
}

bool segment_touches_triangle_3d(const Vec3& a, const Vec3& b,
                                 const Triangle& triangle, double tolerance)
{
    const Vec3 t0=triangle.points[0];
    const Vec3 normal=cross(subtract(triangle.points[1],t0),
                            subtract(triangle.points[2],t0));
    const double nlen=length(normal);
    if (nlen<=EPSILON) return false;
    const double da=dot(subtract(a,t0),normal)/nlen;
    const double db=dot(subtract(b,t0),normal)/nlen;
    if (da > tolerance && db > tolerance) return false;
    if (da < -tolerance && db < -tolerance) return false;
    if (std::abs(da)<=tolerance && std::abs(db)<=tolerance)
        return triangle_contains_point_3d(triangle,a,1.0e-8) ||
               triangle_contains_point_3d(triangle,b,1.0e-8);
    const double denom=da-db;
    if (std::abs(denom)<=EPSILON) return false;
    const double fraction=da/denom;
    if (fraction < -1.0e-8 || fraction > 1.0+1.0e-8)
        return false;
    const Vec3 contact=add(a,multiply(subtract(b,a),
                            std::max(0.0,std::min(1.0,fraction))));
    return triangle_contains_point_3d(triangle,contact,1.0e-8);
}

bool triangles_touch_in_3d(const Triangle& a, const Triangle& b,
                          double tolerance)
{
    const Aabb aa=triangle_bounds(a),bb=triangle_bounds(b);
    if (aa.maximum.x < bb.minimum.x-tolerance ||
        bb.maximum.x < aa.minimum.x-tolerance ||
        aa.maximum.y < bb.minimum.y-tolerance ||
        bb.maximum.y < aa.minimum.y-tolerance ||
        aa.maximum.z < bb.minimum.z-tolerance ||
        bb.maximum.z < aa.minimum.z-tolerance)
        return false;

    const Vec3 na=cross(subtract(a.points[1],a.points[0]),
                         subtract(a.points[2],a.points[0]));
    const Vec3 nb=cross(subtract(b.points[1],b.points[0]),
                         subtract(b.points[2],b.points[0]));
    const double la=length(na),lb=length(nb);
    if (la<=EPSILON || lb<=EPSILON) return true; // Uncertain: do not certify.
    bool coplanar=length(cross(na,nb)) <= la*lb*1.0e-9;
    if (coplanar)
        for (const Vec3& p : b.points)
            if (std::abs(dot(subtract(p,a.points[0]),na))/la > tolerance)
                coplanar=false;
    if (coplanar)
    {
        // Project the two coplanar 3D triangles onto their best 2D plane.
        const Vec3 unit=multiply(na,1.0/la);
        const std::array<double,3> absn{std::abs(unit.x),
                                        std::abs(unit.y),std::abs(unit.z)};
        int drop=0;
        if (absn[1]>absn[drop]) drop=1;
        if (absn[2]>absn[drop]) drop=2;
        const auto project=[drop](const Vec3& p) -> LoopPoint2 {
            if (drop==0) return {p.y,p.z};
            if (drop==1) return {p.x,p.z};
            return {p.x,p.y};
        };
        std::array<LoopPoint2,3> ap,bp;
        for (std::size_t i=0;i<3;++i)
        {
            ap[i]=project(a.points[i]);
            bp[i]=project(b.points[i]);
        }
        const auto within=[](const LoopPoint2& p,
                             const std::array<LoopPoint2,3>& tri) {
            const double x=loop_cross_2d(tri[0],tri[1],p);
            const double y=loop_cross_2d(tri[1],tri[2],p);
            const double z=loop_cross_2d(tri[2],tri[0],p);
            return (x>=-1.0e-8 && y>=-1.0e-8 && z>=-1.0e-8) ||
                   (x<=1.0e-8 && y<=1.0e-8 && z<=1.0e-8);
        };
        for (const auto& p : ap) if (within(p,bp)) return true;
        for (const auto& p : bp) if (within(p,ap)) return true;
        for (std::size_t i=0;i<3;++i)
            for (std::size_t j=0;j<3;++j)
                if (loop_segments_touch(ap[i],ap[(i+1)%3],
                         bp[j],bp[(j+1)%3],tolerance)) return true;
        return false;
    }
    for (std::size_t i=0;i<3;++i)
    {
        if (segment_touches_triangle_3d(a.points[i],a.points[(i+1)%3],b,
                                         tolerance)) return true;
        if (segment_touches_triangle_3d(b.points[i],b.points[(i+1)%3],a,
                                         tolerance)) return true;
    }
    return false;
}

bool polygon_contains_2d(const LoopPoint2& point,
                         const std::vector<LoopPoint2>& polygon,
                         double tolerance)
{
    bool inside=false;
    for (std::size_t i=0;i<polygon.size();++i)
    {
        const auto& a=polygon[i];
        const auto& b=polygon[(i+1)%polygon.size()];
        if (point_on_loop_segment(point,a,b,tolerance)) return true;
        if ((a.y>point.y)!=(b.y>point.y))
            if (point.x < a.x+(point.y-a.y)*(b.x-a.x)/(b.y-a.y))
                inside=!inside;
    }
    return inside;
}

struct LoopMembrane
{
    std::vector<Triangle> triangles;
    Vec3 centroid{0,0,0};
    Vec3 origin{0,0,0},axis_u{0,0,0},axis_v{0,0,0},normal{0,0,0};
    std::vector<LoopPoint2> projected;
};

std::optional<LoopMembrane> triangulate_planar_graph_loop(
    const std::vector<std::size_t>& cycle,
    const std::vector<ReferenceGraphNode>& nodes, double tolerance)
{
    if (cycle.size()<3 || cycle.size()>32) return std::nullopt;
    LoopMembrane membrane;
    std::vector<Vec3> points;
    for (std::size_t id : cycle) points.push_back(nodes[id].point);
    membrane.origin=points[0];
    const Vec3 first_edge=subtract(points[1],points[0]);
    if (length(first_edge)<=tolerance) return std::nullopt;
    membrane.axis_u=normalize(first_edge);
    // Newell normal works on concave planar loops as well.
    Vec3 normal{0,0,0};
    for (std::size_t i=0;i<points.size();++i)
        normal=add(normal,cross(subtract(points[i],points[0]),
               subtract(points[(i+1)%points.size()],points[0])));
    if (length(normal)<=tolerance*tolerance) return std::nullopt;
    membrane.normal=normalize(normal);
    membrane.axis_v=normalize(cross(membrane.normal,membrane.axis_u));
    if (length(cross(membrane.normal,membrane.axis_u))<=0.9)
        return std::nullopt;
    for (const Vec3& point : points)
    {
        const Vec3 offset=subtract(point,membrane.origin);
        if (std::abs(dot(offset,membrane.normal))>tolerance)
            return std::nullopt;
        membrane.projected.push_back(
            {dot(offset,membrane.axis_u),dot(offset,membrane.axis_v)});
    }
    const std::size_t n=points.size();
    for (std::size_t i=0;i<n;++i)
    {
        if (length(subtract(points[i],points[(i+1)%n]))<=tolerance)
            return std::nullopt;
        for (std::size_t j=i+2;j<n;++j)
        {
            if (i==0 && j==n-1) continue;
            if (loop_segments_touch(
                    membrane.projected[i],membrane.projected[(i+1)%n],
                    membrane.projected[j],membrane.projected[(j+1)%n],
                    tolerance)) return std::nullopt;
        }
    }
    double area=0.0;
    for (std::size_t i=0;i<n;++i)
    {
        const auto& a=membrane.projected[i];
        const auto& b=membrane.projected[(i+1)%n];
        area+=a.x*b.y-a.y*b.x;
    }
    if (area<=tolerance*tolerance*8.0)
        return std::nullopt; // Newell makes positive orientation.
    std::vector<std::size_t> remaining(n);
    std::iota(remaining.begin(),remaining.end(),0);
    double total_area=0.0;
    Vec3 moment{0,0,0};
    while (remaining.size()>3)
    {
        bool clipped=false;
        for (std::size_t index=0;index<remaining.size();++index)
        {
            const std::size_t prev=remaining[(index+remaining.size()-1)%remaining.size()];
            const std::size_t mid=remaining[index];
            const std::size_t next=remaining[(index+1)%remaining.size()];
            const double twice=loop_cross_2d(
                membrane.projected[prev],membrane.projected[mid],
                membrane.projected[next]);
            if (twice<=tolerance*tolerance) continue;
            const Triangle ear{{points[prev],points[mid],points[next]}};
            bool occupied=false;
            for (std::size_t other : remaining)
            {
                if (other==prev || other==mid || other==next) continue;
                const auto& p=membrane.projected[other];
                const double s0=loop_cross_2d(
                    membrane.projected[prev],membrane.projected[mid],p);
                const double s1=loop_cross_2d(
                    membrane.projected[mid],membrane.projected[next],p);
                const double s2=loop_cross_2d(
                    membrane.projected[next],membrane.projected[prev],p);
                if (s0>=-tolerance && s1>=-tolerance && s2>=-tolerance)
                {
                    occupied=true;
                    break;
                }
            }
            if (occupied) continue;
            membrane.triangles.push_back(ear);
            const double tri_area=0.5*length(cross(
                subtract(ear.points[1],ear.points[0]),
                subtract(ear.points[2],ear.points[0])));
            moment=add(moment,multiply(triangle_centroid(ear),tri_area));
            total_area+=tri_area;
            remaining.erase(remaining.begin()+static_cast<std::ptrdiff_t>(index));
            clipped=true;
            break;
        }
        if (!clipped) return std::nullopt;
    }
    const Triangle last{{points[remaining[0]],points[remaining[1]],
                          points[remaining[2]]}};
    membrane.triangles.push_back(last);
    const double last_area=0.5*length(cross(
        subtract(last.points[1],last.points[0]),
        subtract(last.points[2],last.points[0])));
    moment=add(moment,multiply(triangle_centroid(last),last_area));
    total_area+=last_area;
    if (total_area<=tolerance*tolerance) return std::nullopt;
    membrane.centroid=multiply(moment,1.0/total_area);
    return membrane;
}

bool membrane_inside_solid(
    const LoopMembrane& membrane, const TriangleBvh& bvh,
    const std::vector<const Triangle*>& solid, double tolerance,
    std::size_t& intersection_budget)
{
    for (const Triangle& patch : membrane.triangles)
    {
        // Check the full triangle geometry, not just its centroid.
        for (const Triangle* face : solid)
        {
            if (intersection_budget==0) return false; // Budget: fail closed.
            --intersection_budget;
            if (triangles_touch_in_3d(patch,*face,tolerance)) return false;
        }
        const Vec3 a=patch.points[0],b=patch.points[1],c=patch.points[2];
        for (const Vec3& p : {
            triangle_centroid(patch),
            multiply(add(add(multiply(a,0.6),multiply(b,0.2)),
                         multiply(c,0.2)),1.0),
            multiply(add(add(multiply(a,0.2),multiply(b,0.6)),
                         multiply(c,0.2)),1.0),
            multiply(add(add(multiply(a,0.2),multiply(b,0.2)),
                         multiply(c,0.6)),1.0)
        })
        {
            if (!bvh_inside(bvh,p,tolerance) ||
                bvh.nearest_distance(p)<=tolerance)
                return false;
        }
    }
    return true;
}

void certify_planar_loop(
    const std::vector<std::size_t>& cycle,
    const std::vector<std::vector<bool>>& linked,
    const std::vector<const Triangle*>& solid,
    const TriangleBvh& bvh,
    ReferenceGraphDebug& graph, double tolerance,
    std::size_t& test_budget)
{
    if (graph.loop_candidates.size()>=256 || test_budget==0) return;
    // A certified ring must be induced: no chord across its membrane.
    for (std::size_t i=0;i<cycle.size();++i)
        for (std::size_t j=i+2;j<cycle.size();++j)
        {
            if (i==0 && j==cycle.size()-1) continue;
            if (linked[cycle[i]][cycle[j]]) return;
        }
    const auto patch=triangulate_planar_graph_loop(cycle,graph.nodes,tolerance);
    if (!patch) return;
    std::vector<bool> is_cycle(graph.nodes.size(),false);
    for (std::size_t v : cycle) is_cycle[v]=true;
    // Do not remove an existing non-loop node whose center lies on the
    // spanning membrane; leave it for an independent safe operation.
    for (std::size_t i=0;i<graph.nodes.size();++i)
    {
        if (is_cycle[i]) continue;
        const Vec3& p=graph.nodes[i].point;
        const Vec3 delta=subtract(p,patch->origin);
        if (std::abs(dot(delta,patch->normal))>tolerance) continue;
        if (polygon_contains_2d(
            {dot(delta,patch->axis_u),dot(delta,patch->axis_v)},
            patch->projected,tolerance)) return;
    }
    if (!membrane_inside_solid(*patch,bvh,solid,tolerance,test_budget))
        return;

    ReferenceLoopCollapseCandidate cert;
    cert.vertices=cycle;

    // An area centroid can lie outside a concave membrane; use ear
    // centroids as fallback, but each proposed center must have direct
    // native LOS to every cycle node (not merely intersecting spheres).
    std::vector<Vec3> centers{patch->centroid};
    for (const Triangle& ear : patch->triangles)
        centers.push_back(triangle_centroid(ear));
    for (const Vec3& center : centers)
    {
        if (!bvh_inside(bvh,center,tolerance)) continue;
        const double radius=bvh.nearest_distance(center)-tolerance;
        if (!std::isfinite(radius) || radius<=tolerance) continue;
        bool all_visible=true;
        for (std::size_t v : cycle)
            if (!clear_path(bvh,center,graph.nodes[v].point,tolerance))
            {
                all_visible=false;
                break;
            }
        if (!all_visible) continue;
        cert.representative={center,radius};
        for (std::size_t i=0;i<graph.nodes.size();++i)
        {
            if (is_cycle[i]) continue;
            if (clear_path(bvh,center,graph.nodes[i].point,tolerance))
                cert.visible_neighbors.push_back(i);
        }
        graph.loop_candidates.push_back(std::move(cert));
        return;
    }
}

void validate_virtual_mesh_loop_candidates(
    const std::vector<const Triangle*>& solid,
    const TriangleBvh& bvh, ReferenceGraphDebug& graph,
    double tolerance)
{
    constexpr std::size_t MAX_NODES=192;
    constexpr std::size_t MAX_PATH_STEPS=80000;
    constexpr std::size_t MAX_TRIANGLE_TESTS=2000000;
    const std::size_t n=graph.nodes.size();
    if (n<3 || n>MAX_NODES || solid.empty()) return;
    std::vector<std::vector<bool>> linked(
        n,std::vector<bool>(n,false));
    std::vector<std::vector<std::size_t>> adjacent(n);
    for (const ReferenceGraphEdge& e : graph.edges)
    {
        if (e.first>=n || e.second>=n) continue;
        linked[e.first][e.second]=linked[e.second][e.first]=true;
        adjacent[e.first].push_back(e.second);
        adjacent[e.second].push_back(e.first);
    }
    std::size_t steps=0,budget=MAX_TRIANGLE_TESTS;
    std::vector<bool> used(n,false);
    std::vector<std::size_t> cycle;
    std::function<void(std::size_t,std::size_t)> walk;
    walk=[&](std::size_t start,std::size_t current)
    {
        if (++steps>MAX_PATH_STEPS || graph.loop_candidates.size()>=256)
            return;
        for (std::size_t next : adjacent[current])
        {
            if (next==start)
            {
                if (cycle.size()>=3 && cycle[1]<cycle.back())
                    certify_planar_loop(cycle,linked,solid,bvh,graph,
                                        tolerance,budget);
                continue;
            }
            if (next<=start || used[next] || cycle.size()>=32)
                continue;
            bool chord=false;
            for (std::size_t i=1;i+1<cycle.size();++i)
                if (linked[next][cycle[i]])
                {
                    chord=true;
                    break;
                }
            if (chord) continue;
            used[next]=true;
            cycle.push_back(next);
            walk(start,next);
            cycle.pop_back();
            used[next]=false;
            if (steps>MAX_PATH_STEPS || budget==0) return;
        }
    };
    for (std::size_t start=0;start<n;++start)
    {
        cycle={start};
        used[start]=true;
        walk(start,start);
        used[start]=false;
        if (steps>MAX_PATH_STEPS || budget==0 ||
            graph.loop_candidates.size()>=256) break;
    }
}
} // namespace

ReferenceGraphDebug build_room_reference_visibility_graph(
    const CellData& cell,
    const std::vector<ReferencePoint>& reference_points,
    double tolerance
)
{
    ReferenceGraphDebug graph;
    if (!std::isfinite(tolerance) || tolerance <= 0.0) return graph;
    const std::vector<const Triangle*> triangles = triangle_pointers(cell);
    if (triangles.empty()) return graph;
    TriangleBvh bvh(triangles);
    if (bvh.empty()) return graph;

    const auto add_node = [&](const Vec3& point) {
        if (!bvh_inside(bvh, point, tolerance)) return;
        const double clearance = bvh.nearest_distance(point);
        if (!std::isfinite(clearance) || clearance <= tolerance) return;
        // True 3D inscribed sphere: nearest floor, ceiling or wall.
        graph.nodes.push_back({point, clearance - tolerance});
    };
    for (const ReferencePoint& point : reference_points)
        if (point.kind == ReferencePointKind::Final)
            add_node(point.point);
    if (graph.nodes.empty()) return graph;

    for (std::size_t i=0; i<graph.nodes.size(); ++i)
    {
        for (std::size_t j=i+1; j<graph.nodes.size(); ++j)
        {
            const auto& first = graph.nodes[i];
            const auto& second = graph.nodes[j];
            const double overlap_radius = first.radius + second.radius;
            if (overlap_radius <= tolerance ||
                length_squared(subtract(first.point, second.point)) >
                    overlap_radius * overlap_radius ||
                !clear_path(bvh, first.point, second.point, tolerance))
                continue;
            graph.edges.push_back({i,j});
        }
    }
    // Room keeps its existing downstream Collapse certificates.
    // Stair is intentionally BEFORE-only in this legacy helper: compute
    // reference nodes and sphere/LOS edges, but NO Collapse candidates.
    if (cell.category == CellSpaceCategory::Room)
    {
        try
        {
            validate_virtual_mesh_loop_candidates(triangles,bvh,graph,tolerance);
        }
        catch (...)
        {
            graph.loop_candidates.clear(); // Fail closed, preserve BEFORE.
        }
    }
    return graph;
}

CellSpaceInteriorPointResult locate_cell_space_interior_points(
    const CellData& cell,
    double tolerance
)
{
    if (cell.category == CellSpaceCategory::Room ||
        cell.category == CellSpaceCategory::Stair)
        return locate_reference_before(cell,tolerance);

    CellSpaceInteriorPointResult result;
    result.state_point = find_state_point(cell, tolerance, &result.state_metrics);
    if (result.state_point) result.exit_code=StateExitCode::Success;

    return result;
}

} // namespace IndoorGMLAdjacencyNative
