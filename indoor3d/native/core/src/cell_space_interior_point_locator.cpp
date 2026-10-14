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
// Room-only reference heuristics; State and Adjacency are unchanged.
// Ignore numerical angle noise; accumulate genuine consecutive reflex turns.
constexpr double ROOM_REFLEX_NOISE_DEGREES = 0.25;
constexpr double ROOM_CUMULATIVE_TURN_DEGREES = 15.0;
// Only remove a middle candidate when a direct shortcut deviates by at most
// 15% of the smallest local corridor width and retains wall clearance.
constexpr double ROOM_SHORTCUT_MAX_DEVIATION_WIDTH_FRACTION = 0.15;
constexpr double ROOM_SHORTCUT_MIN_CLEARANCE_FRACTION = 0.35;
// Each cluster radius is 15% of the local XY corridor width.
constexpr double ROOM_LOCAL_WIDTH_CLUSTER_FRACTION = 0.15;
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

// Local XY width is twice the nearest vertical-wall clearance at State Z.
// Floors and ceilings must not reduce the merger radius.
double nearest_wall_clearance(const std::vector<WallSegment>& walls, const Vec3& p)
{
    double nearest = std::numeric_limits<double>::infinity();
    for (const WallSegment& wall : walls)
    {
        const Vec3 edge = subtract(wall.b, wall.a);
        const double edge_sq = edge.x * edge.x + edge.y * edge.y;
        if (edge_sq <= EPSILON * EPSILON) continue;
        const Vec3 offset = subtract(p, wall.a);
        const double projection = (offset.x * edge.x + offset.y * edge.y) / edge_sq;
        const double t = std::max(0.0, std::min(1.0, projection));
        nearest = std::min(nearest, distance_xy_squared(
            p, add(wall.a, multiply(edge, t))
        ));
    }
    return std::isfinite(nearest) ? std::sqrt(nearest) : 0.0;
}

double local_cluster_radius(const std::vector<WallSegment>& walls, const Vec3& p)
{
    return 2.0 * ROOM_LOCAL_WIDTH_CLUSTER_FRACTION *
           nearest_wall_clearance(walls, p);
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

// Protect the actual 2D Room boundary when deciding whether a candidate
// lies on a redundant detour. A handful of 3D BVH samples alone can miss
// a thin wall between the samples.
bool crosses_wall_slice(
    const std::vector<WallSegment>& walls,
    const Vec3& first,
    const Vec3& last,
    double tolerance
)
{
    const Vec3 chord = subtract(last, first);
    const double length_sq = distance_xy_squared(first, last);
    if (length_sq <= tolerance * tolerance) return true;
    for (const WallSegment& wall : walls)
    {
        const Vec3 edge = subtract(wall.b, wall.a);
        const Vec3 delta = subtract(wall.a, first);
        const double denom = cross_xy(chord, edge);
        if (std::abs(denom) > EPSILON)
        {
            const double t = cross_xy(delta, edge) / denom;
            const double u = cross_xy(delta, chord) / denom;
            const double t_eps = tolerance / std::sqrt(length_sq);
            const double edge_len = std::hypot(edge.x, edge.y);
            const double u_eps = edge_len > EPSILON ? tolerance / edge_len : 0.0;
            if (t >= -t_eps && t <= 1.0 + t_eps &&
                u >= -u_eps && u <= 1.0 + u_eps)
                return true;
        }
        else if (std::abs(cross_xy(delta, chord)) <=
                 tolerance * std::sqrt(length_sq))
        {
            // Collinear or almost collinear overlap is unsafe.
            const double a = dot(subtract(wall.a, first), chord) / length_sq;
            const double b = dot(subtract(wall.b, first), chord) / length_sq;
            if (std::max(a, b) >= 0.0 && std::min(a, b) <= 1.0)
                return true;
        }
    }
    return false;
}

// The candidate to remove must be approximately on a navigable chord,
// and the chord must stay inside the Room without cutting a wall or
// unacceptably reducing corridor clearance.
bool redundant_corner_candidate(
    const TriangleBvh& bvh,
    const std::vector<WallSegment>& walls,
    const Vec3& previous,
    const Vec3& middle,
    const Vec3& next,
    double tolerance
)
{
    const Vec3 chord = subtract(next, previous);
    const double chord_sq = distance_xy_squared(previous, next);
    if (chord_sq <= tolerance * tolerance) return false;

    const Vec3 offset = subtract(middle, previous);
    const double projection =
        (offset.x * chord.x + offset.y * chord.y) / chord_sq;
    if (projection <= 0.0 || projection >= 1.0) return false;

    const Vec3 foot = add(previous, multiply(chord, projection));
    const double deviation = std::sqrt(distance_xy_squared(middle, foot));
    const double min_clearance = std::min({
        nearest_wall_clearance(walls, previous),
        nearest_wall_clearance(walls, middle),
        nearest_wall_clearance(walls, next)
    });
    if (min_clearance <= tolerance * 2.0 ||
        deviation > std::max(
            tolerance,
            2.0 * ROOM_SHORTCUT_MAX_DEVIATION_WIDTH_FRACTION * min_clearance
        ))
        return false;

    if (crosses_wall_slice(walls, previous, next, tolerance)) return false;

    const double min_allowed_clearance = std::max(
        tolerance * 2.0,
        ROOM_SHORTCUT_MIN_CLEARANCE_FRACTION * min_clearance
    );
    for (std::size_t step = 1; step < 8; ++step)
    {
        const Vec3 point = add(previous, multiply(chord, step / 8.0));
        if (!bvh_inside(bvh, point, tolerance) ||
            bvh.nearest_distance(point) <= tolerance ||
            nearest_wall_clearance(walls, point) < min_allowed_clearance)
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

    // Classify corners at the horizontal State slice. Convex corners are
    // barriers for accumulating curvature; collinear seams are passable.
    const std::size_t vertex_count = vertices.size();
    std::vector<double> reflex_turn(vertex_count, 0.0);
    std::vector<Vec3> inward(vertex_count, Vec3{0.0, 0.0, 0.0});
    std::vector<bool> blocked(vertex_count, true);
    for (std::size_t i = 0; i < vertex_count; ++i)
    {
        const CornerVertex& corner = vertices[i];
        if (corner.rays.size() != 2) continue;
        const Vec3 bisector_sum = add(corner.rays[0], corner.rays[1]);
        if (length_squared(bisector_sum) <= EPSILON)
        {
            blocked[i] = false; // Straight seam.
            continue;
        }
        const double cosine = std::max(-1.0, std::min(1.0,
            dot(corner.rays[0], corner.rays[1])));
        const double small_angle =
            std::acos(cosine) * 180.0 / 3.14159265358979323846;
        const Vec3 bisector = normalize(bisector_sum);
        const double probe = std::max(tolerance * 8.0, short_span * 0.01);
        const bool small_inside =
            bvh_inside(bvh, add(corner.point, multiply(bisector, probe)), tolerance);
        const bool reflex_inside =
            bvh_inside(bvh, subtract(corner.point, multiply(bisector, probe)), tolerance);
        if (small_inside == reflex_inside) continue; // Ambiguous junction.
        if (small_inside) continue; // Convex corner breaks the run.
        blocked[i] = false;
        const double turn = 180.0 - small_angle;
        if (turn > ROOM_REFLEX_NOISE_DEGREES)
        {
            reflex_turn[i] = turn;
            inward[i] = multiply(bisector, -1.0);
        }
    }

    // Follow actual wall connectivity (never group unrelated nearby walls).
    std::vector<std::vector<std::size_t>> neighbors(vertex_count);
    const auto index_of = [&](const Vec3& point) {
        for (std::size_t i = 0; i < vertex_count; ++i)
            if (near_xy(vertices[i].point, point, geometry_epsilon)) return i;
        return vertex_count;
    };
    for (const WallSegment& wall : walls)
    {
        const std::size_t a = index_of(wall.a);
        const std::size_t b = index_of(wall.b);
        if (a == b || a == vertex_count || b == vertex_count) continue;
        if (std::find(neighbors[a].begin(), neighbors[a].end(), b) == neighbors[a].end())
            neighbors[a].push_back(b);
        if (std::find(neighbors[b].begin(), neighbors[b].end(), a) == neighbors[b].end())
            neighbors[b].push_back(a);
    }

    // Each uninterrupted reflex arc emits a corner at 15 degrees of
    // cumulative turning. Keep chain membership and order for safe pruning.
    // Non-manifold components retain their individually strong candidates.
    std::vector<std::size_t> selected;
    std::vector<std::vector<std::size_t>> selected_chains;
    std::vector<bool> visited(vertex_count, false);
    std::vector<bool> ordered(vertex_count, false);
    for (std::size_t seed = 0; seed < vertex_count; ++seed)
    {
        if (blocked[seed] || visited[seed]) continue;
        std::vector<std::size_t> component;
        std::vector<std::size_t> stack{seed};
        visited[seed] = true;
        while (!stack.empty())
        {
            const std::size_t v = stack.back();
            stack.pop_back();
            component.push_back(v);
            for (const std::size_t neighbor : neighbors[v])
            {
                if (blocked[neighbor] || visited[neighbor]) continue;
                visited[neighbor] = true;
                stack.push_back(neighbor);
            }
        }
        std::size_t start_vertex = component.front();
        bool found_endpoint = false;
        bool simple = true;
        for (const std::size_t v : component)
        {
            std::size_t degree = 0;
            for (const std::size_t neighbor : neighbors[v])
                if (!blocked[neighbor]) ++degree;
            if (degree > 2) simple = false;
            if (degree <= 1 && !found_endpoint)
            {
                start_vertex = v;
                found_endpoint = true;
            }
        }
        if (!simple)
        {
            for (const std::size_t v : component)
            {
                if (reflex_turn[v] < ROOM_CUMULATIVE_TURN_DEGREES) continue;
                selected.push_back(v);
                selected_chains.push_back({v}); // Do not simplify junctions.
            }
            continue;
        }
        std::vector<std::size_t> chain_candidates;
        const std::size_t none = vertex_count;
        std::size_t previous = none;
        std::size_t current = start_vertex;
        double accumulated = 0.0;
        for (std::size_t n = 0; n < component.size(); ++n)
        {
            if (current == none || ordered[current]) break;
            ordered[current] = true;
            accumulated += reflex_turn[current];
            if (accumulated + 1.0e-9 >= ROOM_CUMULATIVE_TURN_DEGREES)
            {
                if (reflex_turn[current] > 0.0)
                {
                    selected.push_back(current);
                    chain_candidates.push_back(current);
                }
                accumulated = 0.0;
            }
            std::size_t next = none;
            for (const std::size_t neighbor : neighbors[current])
            {
                if (neighbor != previous && !blocked[neighbor] && !ordered[neighbor])
                {
                    next = neighbor;
                    break;
                }
            }
            previous = current;
            current = next;
        }
        if (found_endpoint)
        {
            if (!chain_candidates.empty())
                selected_chains.push_back(std::move(chain_candidates));
        }
        else
        {
            // A closed ring has no safe beginning/end for open-path pruning.
            for (const std::size_t v : chain_candidates)
                selected_chains.push_back({v});
        }
    }
    if (selected.empty()) return {}; // State alone for convex/shallow shapes.

    std::vector<ReferencePoint> points;
    points.reserve(std::min<std::size_t>(
        selected.size() * 3, MAX_ROOM_REFERENCE_POINTS
    ));

    const auto add_candidate = [&](const Vec3& candidate, ReferencePointKind kind) {
        const bool source_candidate = kind == ReferencePointKind::Corner;
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

    // First construct the purple candidates without discarding any geometry
    // information. A chain only contains reflex corners on the same actual
    // vertical-wall boundary. The RGB debug renderer will see the survivors.
    std::vector<std::optional<Vec3>> candidates(vertex_count);
    for (const std::size_t i : selected)
    {
        const Vec3& vertex = vertices[i].point;
        const double probe = std::max(tolerance * 8.0, short_span * 0.01);
        const double distance =
            opposite_wall_distance(walls, vertex, inward[i], tolerance);
        if (!std::isfinite(distance) || distance <= tolerance * 2.0) continue;
        const Vec3 candidate = add(vertex, multiply(inward[i], 0.5 * distance));
        if (safe_reference(bvh, candidate, state_point, tolerance) &&
            clear_path(bvh, add(vertex, multiply(inward[i], probe)), candidate, tolerance))
            candidates[i] = candidate;
    }

    // Remove an intermediate candidate ONLY when the two surrounding
    // surviving candidates have a safe direct chord inside this Room.
    // Keep endpoints, disconnected contours and non-manifold junctions.
    for (const std::vector<std::size_t>& chain : selected_chains)
    {
        std::vector<std::size_t> remaining;
        for (const std::size_t vertex : chain)
            if (candidates[vertex]) remaining.push_back(vertex);

        std::size_t index = 1;
        while (index + 1 < remaining.size())
        {
            const std::size_t previous = remaining[index - 1];
            const std::size_t middle = remaining[index];
            const std::size_t next = remaining[index + 1];
            if (redundant_corner_candidate(
                    bvh, walls,
                    *candidates[previous], *candidates[middle], *candidates[next],
                    tolerance))
            {
                candidates[middle] = std::nullopt;
                remaining.erase(remaining.begin() + static_cast<std::ptrdiff_t>(index));
                if (index > 1) --index;
            }
            else
            {
                ++index;
            }
        }
    }

    // The rest of the pipeline (State-anchored cluster, centroid, final
    // points) is unchanged; only the source candidate set was simplified.
    for (const std::size_t vertex : selected)
        if (candidates[vertex])
            add_candidate(*candidates[vertex], ReferencePointKind::Corner);

    // Cluster only purple corner candidates; the State is a fixed-position
    // special Reference Point and takes priority over ordinary clusters.
    // The State is a special, fixed-position Reference Point during clustering.
    // Process it first so nearby, mutually visible candidates are absorbed
    // into the State instead of being assigned to ordinary clusters.
    // Non-State clusters retain the existing arithmetic-mean representative.
    const std::size_t original_count = points.size();
    std::vector<bool> merged_sources(original_count, false);
    if (original_count > 0)
    {
        std::vector<std::size_t> state_cluster;
        std::vector<std::vector<std::size_t>> clusters;
        const double state_radius = local_cluster_radius(walls, state_point);
        std::vector<double> point_radii(original_count);
        for (std::size_t i = 0; i < original_count; ++i)
            point_radii[i] = local_cluster_radius(walls, points[i].point);

        const auto mutually_compatible = [&](std::size_t index,
                                              const std::vector<std::size_t>& members) {
            for (const std::size_t member : members)
            {
                const double pair_radius = std::min(point_radii[index], point_radii[member]);
                if (pair_radius <= tolerance * 4.0 ||
                    distance_xy_squared(points[index].point, points[member].point) >
                        pair_radius * pair_radius ||
                    !clear_path(bvh, points[index].point, points[member].point, tolerance))
                    return false;
            }
            return true;
        };

        for (std::size_t i = 0; i < original_count; ++i)
        {
            // A State + one candidate is already a valid merge set.
            const double state_pair_radius = std::min(state_radius, point_radii[i]);
            if (state_pair_radius > tolerance * 4.0 &&
                distance_xy_squared(points[i].point, state_point) <=
                    state_pair_radius * state_pair_radius &&
                clear_path(bvh, points[i].point, state_point, tolerance) &&
                mutually_compatible(i, state_cluster))
            {
                state_cluster.push_back(i);
                continue;
            }

            bool appended = false;
            for (std::vector<std::size_t>& cluster : clusters)
            {
                if (!mutually_compatible(i, cluster)) continue;

                cluster.push_back(i);
                appended = true;
                break;
            }
            if (!appended) clusters.push_back({i});
        }

        if (!state_cluster.empty())
        {
            // Red debugging marker at the exact State coordinates.
            // The existing State remains the ONLY final navigation node at
            // this position; no additional black Final point is emitted.
            points.push_back({state_point, ReferencePointKind::Merged});
            for (const std::size_t member : state_cluster)
                merged_sources[member] = true;
        }

        for (const std::vector<std::size_t>& cluster : clusters)
        {
            if (cluster.size() < 2) continue;

            // Ordinary (non-State) clusters continue to use their mean.
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
            if (!valid) continue;

            add_candidate(centroid, ReferencePointKind::Merged);
            for (const std::size_t member : cluster)
                merged_sources[member] = true;
        }
    }

    // Final navigation nodes: each non-State red center plus every unmerged
    // purple corner candidate. The State already represents its own cluster.
    // All diagnostic markers remain visible.
    const std::size_t diagnostic_count = points.size();
    for (std::size_t i = 0; i < diagnostic_count; ++i)
    {
        const bool unmerged_source = i < original_count && !merged_sources[i];
        const bool non_state_center =
            points[i].kind == ReferencePointKind::Merged &&
            !near_xy(points[i].point, state_point, tolerance);
        if (!unmerged_source && !non_state_center) continue;

        // Copy before push_back: vector reallocation may invalidate points[i].
        const Vec3 final_position = points[i].point;
        add_candidate(final_position, ReferencePointKind::Final);
    }
    return points;
}

// Build a diagnostic visibility graph from State and *final* reference nodes.
// Each XY disk is bounded by its nearest vertical wall. The local width
// approximation (2x nearest clearance) must be halved for an inscribed
// circle; the existing 0.15x reference clustering policy stays unchanged.
ReferenceGraphDebug build_room_reference_visibility_graph(
    const CellData& cell,
    const Vec3& state_point,
    const std::vector<ReferencePoint>& reference_points,
    double tolerance
)
{
    ReferenceGraphDebug graph;
    if (!std::isfinite(tolerance) || tolerance <= 0.0) return graph;

    const std::vector<WallSegment> walls =
        wall_segments_at_z(cell, state_point.z, tolerance);
    if (walls.empty()) return graph;

    const std::vector<const Triangle*> triangles = triangle_pointers(cell);
    if (triangles.empty()) return graph;
    TriangleBvh bvh(triangles);
    if (bvh.empty()) return graph;

    const auto add_node = [&](const Vec3& point) {
        const double wall_clearance = nearest_wall_clearance(walls, point);
        if (!std::isfinite(wall_clearance) || wall_clearance <= 0.0) return;

        // XY inscribed circle: r = distance to the nearest wall, not
        // 2x that distance. A small tolerance margin prevents a disk
        // tangent to a wall from visibly crossing it due to FP error.
        const double radius = std::max(0.0, wall_clearance - tolerance);
        graph.nodes.push_back({point, radius});
    };
    add_node(state_point);
    if (graph.nodes.empty()) return graph;

    for (const ReferencePoint& reference : reference_points)
    {
        if (reference.kind != ReferencePointKind::Final) continue;
        add_node(reference.point);
    }

    // AABB-free pair test: only intersecting circles can form an Edge.
    // The current experimental graph is per CellSpace and is never used
    // for Transition computation or destructive reference simplification.
    for (std::size_t i = 0; i < graph.nodes.size(); ++i)
    {
        const ReferenceGraphNode& first = graph.nodes[i];
        for (std::size_t j = i + 1; j < graph.nodes.size(); ++j)
        {
            const ReferenceGraphNode& second = graph.nodes[j];
            const double radius_sum = first.radius + second.radius;
            if (radius_sum <= tolerance ||
                distance_xy_squared(first.point, second.point) >
                    radius_sum * radius_sum)
                continue;
            if (crosses_wall_slice(walls, first.point, second.point, tolerance))
                continue;
            if (!clear_path(bvh, first.point, second.point, tolerance))
                continue;
            graph.edges.push_back({i, j});
        }
    }
    // Failure to prevalidate optional collapse candidates must not erase the
    // already successful State, Reference Points, circles, or LOS edges.
    try
    {
    // Prevalidate NEW points while the original cell geometry/BVH is still
    // available. Ruby cannot safely invent visibility edges after this Native
    // geometry session is closed. This does not collapse the original graph.
    constexpr std::size_t MAX_LOOP_GRAPH_NODES = 192;
    constexpr std::size_t MAX_LOOP_CANDIDATES = 768;
    const std::size_t count = graph.nodes.size();
    if (count <= MAX_LOOP_GRAPH_NODES)
    {
        std::vector<std::vector<bool>> linked(
            count, std::vector<bool>(count, false));
        for (const ReferenceGraphEdge& edge : graph.edges)
        {
            linked[edge.first][edge.second] = true;
            linked[edge.second][edge.first] = true;
        }
        const auto may_connect = [&](const Vec3& point, double radius,
                                     std::size_t other) {
            const ReferenceGraphNode& target = graph.nodes[other];
            const double sum = radius + target.radius;
            if (sum <= tolerance ||
                distance_xy_squared(point, target.point) > sum * sum)
                return false;
            if (crosses_wall_slice(walls, point, target.point, tolerance))
                return false;
            return clear_path(bvh, point, target.point, tolerance);
        };

        // Exclude triangles containing State: Ruby handles those by retaining
        // State itself and validating its existing, immutable edges.
        for (std::size_t i = 1; i < count; ++i)
        {
            for (std::size_t j = i + 1; j < count; ++j)
            {
                if (!linked[i][j]) continue;
                for (std::size_t k = j + 1; k < count; ++k)
                {
                    if (!linked[i][k] || !linked[j][k]) continue;
                    const Vec3& a = graph.nodes[i].point;
                    const Vec3& b = graph.nodes[j].point;
                    const Vec3& c = graph.nodes[k].point;
                    const double twice_area =
                        std::abs(cross_xy(subtract(b, a), subtract(c, a)));
                    if (twice_area <= tolerance * tolerance * 16.0) continue;
                    const Vec3 center{
                        (a.x + b.x + c.x) / 3.0,
                        (a.y + b.y + c.y) / 3.0,
                        state_point.z
                    };
                    const double wall_distance = nearest_wall_clearance(walls, center);
                    if (!std::isfinite(wall_distance) ||
                        wall_distance <= tolerance * 2.0 ||
                        !bvh_inside(bvh, center, tolerance) ||
                        bvh.nearest_distance(center) <= tolerance)
                        continue;
                    const double radius = wall_distance - tolerance;

                    ReferenceLoopCollapseCandidate candidate;
                    candidate.triangle = {i, j, k};
                    candidate.representative = {center, radius};
                    // All original loop vertices must see the replacement;
                    // otherwise never transmit an invalid candidate.
                    if (!may_connect(center, radius, i) ||
                        !may_connect(center, radius, j) ||
                        !may_connect(center, radius, k))
                        continue;
                    for (std::size_t neighbor = 0; neighbor < count; ++neighbor)
                    {
                        if (neighbor == i || neighbor == j || neighbor == k) continue;
                        if (may_connect(center, radius, neighbor))
                            candidate.visible_neighbors.push_back(neighbor);
                    }
                    graph.loop_candidates.push_back(std::move(candidate));
                    if (graph.loop_candidates.size() >= MAX_LOOP_CANDIDATES)
                        return graph;
                }
            }
        }
    }
    }
    catch (...)
    {
        graph.loop_candidates.clear();
    }
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
            result.reference_points = find_reference_points(
                cell,
                *result.state_point,
                tolerance
            );
            result.reference_status = ReferencePointStatus::Succeeded;
            // Debug-only output: isolate graph failures from State and the
            // already-computed final Reference Points.
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
