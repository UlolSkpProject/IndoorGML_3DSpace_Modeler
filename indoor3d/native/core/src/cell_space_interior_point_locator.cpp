#include "cell_space_interior_point_locator.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
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
// The same threshold as the SFO diagnostic: normal.z <= -0.1 for a
// normalized outward-facing solid Face. Inclined floors are included.
constexpr double ROOM_FLOOR_MIN_NEGATIVE_NORMAL_Z = 0.1;
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

// Floor-triangle experiment: every floor face is already triangulated in the
// native geometry snapshot (FaceData::triangles), including holes and slopes.
// An eligible triangle's arithmetic centroid is moved exactly +1000 mm along
// WORLD Z, not along the triangle normal. Only valid points inside the whole
// CellSpace Solid are retained. Do not merge/prune seeds here: BEFORE must
// show the complete candidate set, and AFTER onward owns graph reduction.
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

    std::vector<ReferencePoint> points;
    points.reserve(std::min<std::size_t>(
        solid_triangles.size() * 2, MAX_ROOM_REFERENCE_DEBUG_POINTS));

    const double minimum_state_distance_squared = tolerance * tolerance;
    std::size_t accepted = 0;

    for (const FaceData& face : cell.faces)
    {
        const double normal_length = length(face.normal);
        if (!std::isfinite(normal_length) || normal_length <= EPSILON ||
            face.normal.z > -ROOM_FLOOR_MIN_NEGATIVE_NORMAL_Z * normal_length)
            continue;

        for (const Triangle& triangle : face.triangles)
        {
            // Degenerate triangles do not have a usable floor surface.
            const Vec3 ab = subtract(triangle.points[1], triangle.points[0]);
            const Vec3 ac = subtract(triangle.points[2], triangle.points[0]);
            if (length_squared(cross(ab, ac)) <= EPSILON) continue;

            Vec3 point = multiply(add(add(triangle.points[0],
                                          triangle.points[1]),
                                          triangle.points[2]), 1.0 / 3.0);
            point.z += ROOM_REFERENCE_FLOOR_OFFSET;
            if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
                !std::isfinite(point.z) ||
                !bvh_inside(bvh, point, tolerance) ||
                bvh.nearest_distance(point) <= tolerance)
                continue;

            // Face is the original green 1st-stage diagnostic marker.
            // Final is the SAME spatial candidate passed into BEFORE.
            // Only the State position itself is represented by State, to
            // avoid adding two coincident graph nodes.
            points.push_back({point, ReferencePointKind::Face});
            if (length_squared(subtract(point, state_point)) >
                minimum_state_distance_squared)
                points.push_back({point, ReferencePointKind::Final});
            ++accepted;
            if (accepted >= MAX_ROOM_REFERENCE_POINTS)
                return points;
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
