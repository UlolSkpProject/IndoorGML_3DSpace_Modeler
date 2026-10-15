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
// Room floor triangulation experiment; State and Adjacency stay unchanged.
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
bool safe_reference(
    const TriangleBvh& bvh,
    const Vec3& point,
    const Vec3& state_point,
    double tolerance
)
{
    return length_squared(subtract(point, state_point)) > tolerance * tolerance &&
           bvh_inside(bvh, point, tolerance) &&
           bvh.nearest_distance(point) > tolerance;
}


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
// edges match. The original geometry and its triangles are never modified.
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

std::vector<FloorRegion> merge_convex_floor_triangles(
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

} // namespace

// Per accepted Floor-region: area-weighted surface centroid + 1000 mm on
// world Z. If a merged region's elevated centroid is not inside the
// Solid, fall back to its original triangles, preserving valid references.
// Native does not pre-merge final graph nodes; AFTER continues to do that.
std::vector<ReferencePoint> find_reference_points(
    const CellData& cell,
    const Vec3& state_point,
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

    const std::vector<FloorRegion> regions = merge_convex_floor_triangles(
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
        survivors.size() * 2, MAX_ROOM_REFERENCE_DEBUG_POINTS));
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
        // State owns its position; do not duplicate it as a Final node.
        if (length_squared(subtract(point, state_point)) >
            tolerance * tolerance)
            points.push_back({point, ReferencePointKind::Final});
        ++accepted;
        return true;
    };

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
    return points;
}

// Graph stage is unchanged: Final markers are the valid floor-triangle
// candidates; sphere overlap and exact 3D LOS determine BEFORE edges.
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

ReferenceGraphDebug build_room_reference_visibility_graph(
    const CellData& cell,
    const Vec3& state_point,
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
    add_node(state_point);
    if (graph.nodes.empty()) return graph;
    for (const ReferencePoint& point : reference_points)
        if (point.kind == ReferencePointKind::Final)
            add_node(point.point);

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
    // TODO(reference-loop-3d): Native V7's prior planar loop-hole test is
    // unsafe for noncoplanar 3D graphs. Generate NO Collapse certificates
    // until exact 3D enclosed-boundary/Hole verification is implemented.
    // The Ruby COLLAPSED stage therefore leaves this graph unchanged;
    // State and valid edges remain available.
    return graph;
}

CellSpaceInteriorPointResult locate_cell_space_interior_points(
    const CellData& cell,
    double tolerance
)
{
    CellSpaceInteriorPointResult result;
    result.state_point = find_state_point(cell, tolerance, &result.state_metrics);
    if (!result.state_point) return result;

    try
    {
        switch (cell.category)
        {
        case CellSpaceCategory::Room:
            // TEMP DEBUG SUPPORT: status is serialized only so Ruby can distinguish
            // a successful empty result from an exception. Remove with debug logging.
            result.reference_status = ReferencePointStatus::Failed;
            // Experimental: floor-triangle centroid + world-Z 1000 mm.
            // No legacy wall-corner candidates or pre-BEFORE clustering.
            result.reference_points = find_reference_points(
                cell, *result.state_point, tolerance
            );
            result.reference_status = ReferencePointStatus::Succeeded;
            // Reference failure is auxiliary; the valid State survives.
            try
            {
                result.debug_graph = build_room_reference_visibility_graph(
                    cell, *result.state_point, result.reference_points, tolerance
                );
            }
            catch (...)
            {
                result.debug_graph = {};
            }
            break;
        case CellSpaceCategory::Stair:
            // TODO: Generate Stair reference points using the State-to-floor distance scale.
            break;
        case CellSpaceCategory::Elevator:
        case CellSpaceCategory::Door:
        case CellSpaceCategory::Window:
        case CellSpaceCategory::Unknown:
        default:
            break;
        }
    }
    catch (...)
    {
        // Reference-point generation is strictly auxiliary. A valid State point
        // must remain usable even when reference-point generation fails.
        result.reference_points.clear();
    }

    return result;
}

} // namespace IndoorGMLAdjacencyNative
