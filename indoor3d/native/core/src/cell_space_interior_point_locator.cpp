#include "cell_space_interior_point_locator.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
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
// Experimental Room-only reference points. This does not affect State or Adjacency.
// Merged reference radius is intentionally configurable until a final scale is chosen.
constexpr double ROOM_REFERENCE_CLUSTER_RADIUS_FRACTION = 0.18;
constexpr double CORNER_CONVEX_THRESHOLD_DEGREES = 145.0;
constexpr double CORNER_REFLEX_THRESHOLD_DEGREES = 225.0;
constexpr std::size_t MAX_ROOM_WALL_SEGMENTS = 2048;
constexpr std::size_t MAX_ROOM_REFERENCE_POINTS = 4096;
// Additional debug records (red merged + black final) do not consume the
// original Face/Corner sampling cap.
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
struct WallSegment
{
    Vec3 a;
    Vec3 b;
};

double cross_xy(const Vec3& a, const Vec3& b)
{
    return a.x * b.y - a.y * b.x;
}

double distance_xy_squared(const Vec3& a, const Vec3& b)
{
    const double dx = a.x - b.x;
    const double dy = a.y - b.y;
    return dx * dx + dy * dy;
}

bool near_xy(const Vec3& a, const Vec3& b, double epsilon)
{
    return distance_xy_squared(a, b) <= epsilon * epsilon;
}

std::vector<WallSegment> wall_segments_at_z(
    const CellData& cell, double z, double tolerance
)
{
    std::vector<WallSegment> segments;
    const double z_epsilon = std::max(tolerance * 0.01, 1.0e-9);
    const double xy_epsilon = std::max(tolerance * 0.01, 1.0e-9);

    for (const FaceData& face : cell.faces)
    {
        const double horizontal_normal = std::hypot(face.normal.x, face.normal.y);
        if (horizontal_normal <= EPSILON ||
            std::abs(face.normal.z) > horizontal_normal * 1.0e-6 ||
            face.outer_points.size() < 3)
            continue;

        const Vec3 tangent = normalize(Vec3{-face.normal.y, face.normal.x, 0.0});
        std::vector<Vec3> intersections;
        const std::vector<Vec3>& ring = face.outer_points;
        for (std::size_t i = 0; i < ring.size(); ++i)
        {
            const Vec3& first = ring[i];
            const Vec3& second = ring[(i + 1) % ring.size()];
            const double z1 = first.z - z;
            const double z2 = second.z - z;
            if (std::abs(z1) <= z_epsilon && std::abs(z2) <= z_epsilon)
            {
                if (!near_xy(first, second, xy_epsilon))
                    intersections.push_back(first), intersections.push_back(second);
                continue;
            }
            // Half-open intersection prevents counting vertices twice.
            if ((z1 <= 0.0 && z2 > 0.0) || (z2 <= 0.0 && z1 > 0.0))
            {
                const double t = (z - first.z) / (second.z - first.z);
                intersections.push_back({
                    first.x + t * (second.x - first.x),
                    first.y + t * (second.y - first.y),
                    z
                });
            }
        }

        std::sort(intersections.begin(), intersections.end(),
            [&](const Vec3& lhs, const Vec3& rhs) {
                return dot(lhs, tangent) < dot(rhs, tangent);
            });
        intersections.erase(std::unique(intersections.begin(), intersections.end(),
            [&](const Vec3& lhs, const Vec3& rhs) {
                return near_xy(lhs, rhs, xy_epsilon);
            }), intersections.end());

        // SketchUp polygon rings yield even intersections. An odd number can
        // occur with a triangulated input ring: recover its extremal slice.
        if (intersections.size() % 2 != 0 && intersections.size() >= 2)
        {
            intersections = {intersections.front(), intersections.back()};
        }
        for (std::size_t i = 1; i < intersections.size(); i += 2)
        {
            WallSegment segment{intersections[i - 1], intersections[i]};
            segment.a.z = z;
            segment.b.z = z;
            if (near_xy(segment.a, segment.b, xy_epsilon)) continue;
            const bool duplicate = std::any_of(segments.begin(), segments.end(),
                [&](const WallSegment& other) {
                    return (near_xy(other.a, segment.a, xy_epsilon) &&
                            near_xy(other.b, segment.b, xy_epsilon)) ||
                           (near_xy(other.a, segment.b, xy_epsilon) &&
                            near_xy(other.b, segment.a, xy_epsilon));
                });
            if (!duplicate) segments.push_back(segment);
            if (segments.size() >= MAX_ROOM_WALL_SEGMENTS) return segments;
        }
    }
    return segments;
}

// First strictly-positive intersection of the directed ray with a wall slice.
// This uses the wall cross-section rather than ray/triangle intersections,
// avoiding duplicate hits along SketchUp triangulation edges.
double opposite_wall_distance(
    const std::vector<WallSegment>& walls,
    const Vec3& origin,
    const Vec3& direction,
    double tolerance
)
{
    double best = std::numeric_limits<double>::infinity();
    for (const WallSegment& wall : walls)
    {
        const Vec3 edge = subtract(wall.b, wall.a);
        const double denominator = cross_xy(direction, edge);
        if (std::abs(denominator) <= EPSILON) continue;
        const Vec3 delta = subtract(wall.a, origin);
        const double t = cross_xy(delta, edge) / denominator;
        const double u = cross_xy(delta, direction) / denominator;
        if (t <= tolerance * 4.0 || u < -1.0e-9 || u > 1.0 + 1.0e-9)
            continue;
        best = std::min(best, t);
    }
    return best;
}

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
    for (const double t : {0.25, 0.5, 0.75})
    {
        const Vec3 candidate = add(first, multiply(subtract(second, first), t));
        if (!bvh_inside(bvh, candidate, tolerance) ||
            bvh.nearest_distance(candidate) <= tolerance)
            return false;
    }
    return true;
}

struct CornerVertex
{
    Vec3 point;
    std::vector<Vec3> rays;
};
} // namespace

std::vector<ReferencePoint> find_reference_points(
    const CellData& cell,
    const Vec3& state_point,
    double tolerance
)
{
    if (!(tolerance > 0.0) || !std::isfinite(tolerance))
        return {};

    const double width = cell.bounds.maximum.x - cell.bounds.minimum.x;
    const double height = cell.bounds.maximum.y - cell.bounds.minimum.y;
    if (width <= tolerance || height <= tolerance)
        return {};
    const double short_span = std::min(width, height);
    const double long_span = std::max(width, height);
    const double geometry_epsilon = std::max(tolerance * 0.05, long_span * 1.0e-9);

    const std::vector<const Triangle*> triangles = triangle_pointers(cell);
    if (triangles.empty()) return {};
    TriangleBvh bvh(triangles);
    if (bvh.empty()) return {};

    const std::vector<WallSegment> walls =
        wall_segments_at_z(cell, state_point.z, tolerance);
    if (walls.empty()) return {};

    std::vector<ReferencePoint> points;
    points.reserve(std::min<std::size_t>(walls.size() * 2, MAX_ROOM_REFERENCE_POINTS));

    const auto add_candidate = [&](const Vec3& candidate, ReferencePointKind kind) {
        const bool source_candidate =
            kind == ReferencePointKind::Face || kind == ReferencePointKind::Corner;
        const std::size_t limit = source_candidate ?
            MAX_ROOM_REFERENCE_POINTS : MAX_ROOM_REFERENCE_DEBUG_POINTS;
        if (points.size() >= limit) return;
        if (!safe_reference(bvh, candidate, state_point, tolerance)) return;
        const double duplicate_distance =
            std::max(tolerance * 2.0, long_span * 1.0e-7);
        for (const ReferencePoint& existing : points)
        {
            if (existing.kind == kind &&
                near_xy(existing.point, candidate, duplicate_distance))
                return;
        }
        points.push_back({candidate, kind});
    };

    // Green: midpoint of each vertical Face slice -> half the inward ray
    // distance to the next wall at State's exact Z.
    for (const WallSegment& wall : walls)
    {
        const Vec3 origin = multiply(add(wall.a, wall.b), 0.5);
        const Vec3 edge = subtract(wall.b, wall.a);
        const double edge_length = std::hypot(edge.x, edge.y);
        if (edge_length <= tolerance) continue;
        const Vec3 left{-edge.y / edge_length, edge.x / edge_length, 0.0};
        const double probe = std::max(
            tolerance * 8.0,
            std::min(edge_length * 0.01, short_span * 0.02)
        );
        const bool left_inside = bvh_inside(bvh, add(origin, multiply(left, probe)), tolerance);
        const bool right_inside = bvh_inside(bvh, subtract(origin, multiply(left, probe)), tolerance);
        if (left_inside == right_inside) continue;
        const Vec3 inward = left_inside ? left : multiply(left, -1.0);
        const double distance = opposite_wall_distance(walls, origin, inward, tolerance);
        if (!std::isfinite(distance) || distance <= tolerance * 2.0) continue;
        const Vec3 candidate = add(origin, multiply(inward, distance * 0.5));
        if (clear_path(bvh, add(origin, multiply(inward, probe)), candidate, tolerance))
            add_candidate(candidate, ReferencePointKind::Face);
    }

    // Collect shared endpoints of vertical slices. Only degree-two vertices
    // define an unambiguous corner; seam vertices and junctions are excluded.
    std::vector<CornerVertex> vertices;
    const auto add_ray = [&](const Vec3& point, const Vec3& toward) {
        const Vec3 direction = subtract(toward, point);
        const double edge_length = std::hypot(direction.x, direction.y);
        if (edge_length <= tolerance) return;
        CornerVertex* vertex = nullptr;
        for (CornerVertex& candidate : vertices)
        {
            if (near_xy(candidate.point, point, geometry_epsilon))
            {
                vertex = &candidate;
                break;
            }
        }
        if (!vertex)
        {
            vertices.push_back({point, {}});
            vertex = &vertices.back();
        }
        const Vec3 unit{direction.x / edge_length, direction.y / edge_length, 0.0};
        for (const Vec3& existing : vertex->rays)
        {
            if (dot(existing, unit) > 1.0 - 1.0e-8) return;
        }
        vertex->rays.push_back(unit);
    };
    for (const WallSegment& wall : walls)
    {
        add_ray(wall.a, wall.b);
        add_ray(wall.b, wall.a);
    }

    // Purple: small (<145deg) or reflex (>=225deg) interior corners.
    for (const CornerVertex& vertex : vertices)
    {
        if (vertex.rays.size() != 2) continue;
        const Vec3& first = vertex.rays[0];
        const Vec3& second = vertex.rays[1];
        const double cosine = std::max(-1.0, std::min(1.0, dot(first, second)));
        const double smaller_angle = std::acos(cosine) * 180.0 / 3.14159265358979323846;
        const Vec3 sum = add(first, second);
        if (length_squared(sum) <= EPSILON) continue;
        const Vec3 bisector = normalize(sum);
        const double probe = std::max(tolerance * 8.0, short_span * 0.01);
        const bool narrow_inside =
            bvh_inside(bvh, add(vertex.point, multiply(bisector, probe)), tolerance);
        const bool reflex_inside =
            bvh_inside(bvh, subtract(vertex.point, multiply(bisector, probe)), tolerance);
        if (narrow_inside == reflex_inside) continue;
        const double interior_angle = narrow_inside ?
            smaller_angle : 360.0 - smaller_angle;
        if (!(interior_angle < CORNER_CONVEX_THRESHOLD_DEGREES ||
              interior_angle >= CORNER_REFLEX_THRESHOLD_DEGREES))
            continue;
        const Vec3 inward = narrow_inside ? bisector : multiply(bisector, -1.0);
        const double distance =
            opposite_wall_distance(walls, vertex.point, inward, tolerance);
        if (!std::isfinite(distance) || distance <= tolerance * 2.0) continue;
        const Vec3 candidate =
            add(vertex.point, multiply(inward, distance * 0.5));
        if (clear_path(bvh, add(vertex.point, multiply(inward, probe)), candidate, tolerance))
            add_candidate(candidate, ReferencePointKind::Corner);
    }

    // Red: representative for a close, mutually visible group of green/purple
    // candidates. Keep originals rendered so all three point types can be
    // inspected independently. Complete-link avoids chain-merging across rooms.
    const std::size_t original_count = points.size();
    std::vector<bool> merged_sources(original_count, false);
    const double radius = short_span * ROOM_REFERENCE_CLUSTER_RADIUS_FRACTION;
    if (radius > tolerance * 4.0 && original_count >= 2)
    {
        std::vector<std::vector<std::size_t>> clusters;
        for (std::size_t i = 0; i < original_count; ++i)
        {
            bool appended = false;
            for (std::vector<std::size_t>& cluster : clusters)
            {
                bool compatible = true;
                for (const std::size_t member : cluster)
                {
                    if (distance_xy_squared(points[i].point, points[member].point) >
                            radius * radius ||
                        !clear_path(bvh, points[i].point, points[member].point, tolerance))
                    {
                        compatible = false;
                        break;
                    }
                }
                if (compatible)
                {
                    cluster.push_back(i);
                    appended = true;
                    break;
                }
            }
            if (!appended) clusters.push_back({i});
        }
        for (const std::vector<std::size_t>& cluster : clusters)
        {
            if (cluster.size() < 2) continue;
            Vec3 centroid{0.0, 0.0, state_point.z};
            for (const std::size_t member : cluster)
            {
                centroid.x += points[member].point.x;
                centroid.y += points[member].point.y;
            }
            centroid.x /= static_cast<double>(cluster.size());
            centroid.y /= static_cast<double>(cluster.size());
            bool valid = safe_reference(bvh, centroid, state_point, tolerance);
            for (const std::size_t member : cluster)
            {
                if (valid && !clear_path(bvh, points[member].point, centroid, tolerance))
                    valid = false;
            }
            if (valid)
            {
                add_candidate(centroid, ReferencePointKind::Merged);
                // Source candidates belonging to a successful cluster must
                // NOT also become final points.
                for (const std::size_t member : cluster)
                    merged_sources[member] = true;
            }
        }
    }

    // Black: exactly one final node for each accepted red cluster center,
    // plus every green/purple candidate not absorbed by a cluster.
    // Keep the diagnostic candidates intact for visual comparison.
    const std::size_t diagnostic_count = points.size();
    for (std::size_t i = 0; i < diagnostic_count; ++i)
    {
        const bool unmerged_source = i < original_count && !merged_sources[i];
        const bool merged_center = points[i].kind == ReferencePointKind::Merged;
        if (!unmerged_source && !merged_center) continue;

        const Vec3 candidate = points[i].point;
        add_candidate(candidate, ReferencePointKind::Final);
    }
    return points;
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
            result.reference_points = find_reference_points(
                cell,
                *result.state_point,
                tolerance
            );
            result.reference_status = ReferencePointStatus::Succeeded;
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
