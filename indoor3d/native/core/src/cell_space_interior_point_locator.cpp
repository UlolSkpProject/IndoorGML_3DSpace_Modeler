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
// Signed local exterior turn: reflex < 0, convex > 0, straight = 0.
// Ignore numerical angle noise and emit at a cumulative -30 degree turn.
constexpr double ROOM_REFLEX_NOISE_DEGREES = 0.25;
constexpr double ROOM_CUMULATIVE_TURN_DEGREES = 30.0;
// Maximum |normal.z| / hypot(normal.x, normal.y) for a Room wall.
// Classifies Face topology directly, without any horizontal wall slicing.
constexpr double ROOM_WALL_MAX_NORMAL_Z_XY_RATIO = 0.1;
// Fraction of the inward corner ray to the first opposite vertical wall.
// 0.55 places the purple Corner candidate 55% of the way from the corner.
constexpr double ROOM_REFERENCE_INWARD_DISTANCE_FRACTION = 0.55;
// Only remove a middle candidate when a direct shortcut deviates by at most
// 15% of the smallest local corridor width and retains wall clearance.
constexpr double ROOM_SHORTCUT_MAX_DEVIATION_WIDTH_FRACTION = 0.15;
constexpr double ROOM_SHORTCUT_MIN_CLEARANCE_FRACTION = 0.35;
// Each cluster radius is 15% of the local XY corridor width.
constexpr double ROOM_LOCAL_WIDTH_CLUSTER_FRACTION = 0.15;
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

// Reference anchors are located directly on 3D wall/wall shared edges,
// 1000 mm above their lowest endpoint (no State-Z or Floor-Z slicing).
constexpr double ROOM_REFERENCE_EDGE_OFFSET = 1000.0 / 25.4;

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

struct CornerVertex
{
    Vec3 point;
    std::vector<Vec3> rays;
    // Two actual 3D wall faces meeting along a shared SketchUp edge.
    // Empty for the preserved legacy State-Z debug graph path.
    std::vector<std::size_t> incident_faces;
};

// Match exact solid boundary edges in 3D (quantized only to tolerate tiny
// transformed-coordinate noise). XY coincidence alone is NOT adjacency.
using TopologyVertexKey = std::array<std::int64_t, 3>;
using TopologyEdgeKey = std::pair<TopologyVertexKey, TopologyVertexKey>;
struct TopologyFaceEdge
{
    std::size_t face_index = 0;
    Vec3 first;
    Vec3 second;
};

std::optional<TopologyVertexKey> topology_vertex_key(
    const Vec3& point, double epsilon
)
{
    const auto quantize = [epsilon](double v) -> std::optional<std::int64_t> {
        const double scaled = v / epsilon;
        if (!std::isfinite(scaled) ||
            std::abs(scaled) >= static_cast<double>(
                std::numeric_limits<std::int64_t>::max() / 2))
            return std::nullopt;
        return static_cast<std::int64_t>(std::llround(scaled));
    };
    const auto x = quantize(point.x);
    const auto y = quantize(point.y);
    const auto z = quantize(point.z);
    if (!x || !y || !z) return std::nullopt;
    return TopologyVertexKey{*x, *y, *z};
}

// At a wall/wall shared edge, each planar face supplies the horizontal
// direction pointing from that edge INTO the face, not along the shared edge.
// The XY-projected normal defines the wall tangent; the polygon centroid
// chooses its correct sign. Vertical tilts cannot generate a fake XY turn.
std::optional<Vec3> topology_wall_ray(
    const FaceData& face, const Vec3& first, const Vec3& second
)
{
    const double horizontal = std::hypot(face.normal.x, face.normal.y);
    if (horizontal <= EPSILON) return std::nullopt;
    const Vec3 tangent{-face.normal.y / horizontal,
                        face.normal.x / horizontal, 0.0};
    const Vec3 midpoint = multiply(add(first, second), 0.5);
    double projected = 0.0;
    for (const Vec3& point : face.outer_points)
        projected += dot(subtract(point, midpoint), tangent);
    if (std::abs(projected) <= EPSILON * face.outer_points.size())
        return std::nullopt;
    return projected > 0.0 ? tangent : multiply(tangent, -1.0);
}

// The corner graph is built from SHARED 3D FACE EDGES, not from the
// accidental meeting of equal-Z wall-slice endpoints.
std::vector<CornerVertex> topology_wall_corners(
    const CellData& cell,
    double tolerance,
    double geometry_epsilon
)
{
    std::map<TopologyEdgeKey, std::vector<TopologyFaceEdge>> edge_faces;
    const double z_epsilon = std::max(tolerance * 0.01, 1.0e-9);
    const double edge_epsilon = std::max(geometry_epsilon, 1.0e-9);
    const auto near_3d = [edge_epsilon](const Vec3& a, const Vec3& b) {
        return length_squared(subtract(a, b)) <=
               edge_epsilon * edge_epsilon;
    };
    for (std::size_t face_index = 0; face_index < cell.faces.size(); ++face_index)
    {
        const FaceData& face = cell.faces[face_index];
        const double normal_xy = std::hypot(face.normal.x, face.normal.y);
        if (normal_xy <= EPSILON ||
            std::abs(face.normal.z) >
                normal_xy * ROOM_WALL_MAX_NORMAL_Z_XY_RATIO ||
            face.outer_points.size() < 3)
            continue;

        const std::vector<Vec3>& ring = face.outer_points;
        for (std::size_t i = 0; i < ring.size(); ++i)
        {
            const Vec3& first = ring[i];
            const Vec3& second = ring[(i + 1) % ring.size()];
            // Only an edge with at least 1000 mm of vertical extent
            // has a valid reference anchor. Never extrapolate its ends.
            if (std::abs(second.z - first.z) <
                ROOM_REFERENCE_EDGE_OFFSET - z_epsilon)
                continue;

            const auto first_key = topology_vertex_key(first, edge_epsilon);
            const auto second_key = topology_vertex_key(second, edge_epsilon);
            if (!first_key || !second_key || *first_key == *second_key)
                continue;
            const TopologyEdgeKey key = *first_key < *second_key ?
                TopologyEdgeKey{*first_key, *second_key} :
                TopologyEdgeKey{*second_key, *first_key};
            edge_faces[key].push_back({face_index, first, second});
        }
    }

    std::vector<CornerVertex> corners;
    for (const auto& item : edge_faces)
    {
        const std::vector<TopologyFaceEdge>& shared = item.second;
        // A manifold wall edge is incident to precisely two faces.
        // Higher-degree/nonmanifold junctions are not guessed.
        if (shared.size() != 2 ||
            shared[0].face_index == shared[1].face_index)
            continue;
        const TopologyFaceEdge& first = shared[0];
        const TopologyFaceEdge& second = shared[1];
        if (!((near_3d(first.first, second.first) &&
               near_3d(first.second, second.second)) ||
              (near_3d(first.first, second.second) &&
               near_3d(first.second, second.first))))
            continue;

        const double dz = first.second.z - first.first.z;
        if (std::abs(dz) < ROOM_REFERENCE_EDGE_OFFSET - z_epsilon)
            continue;
        const double anchor_z = std::min(first.first.z, first.second.z) +
                                ROOM_REFERENCE_EDGE_OFFSET;
        const double fraction = (anchor_z - first.first.z) / dz;
        if (fraction < -1.0e-8 || fraction > 1.0 + 1.0e-8)
            continue;
        const Vec3 anchor = add(first.first,
            multiply(subtract(first.second, first.first),
                     std::max(0.0, std::min(1.0, fraction))));
        const FaceData& face_a = cell.faces[first.face_index];
        const FaceData& face_b = cell.faces[second.face_index];
        const auto ray_a = topology_wall_ray(
            face_a, first.first, first.second);
        const auto ray_b = topology_wall_ray(
            face_b, second.first, second.second);
        if (!ray_a || !ray_b) continue;

        Vec3 a = *ray_a;
        Vec3 b = *ray_b;
        const double n1 = std::hypot(face_a.normal.x, face_a.normal.y);
        const double n2 = std::hypot(face_b.normal.x, face_b.normal.y);
        if (n1 <= EPSILON || n2 <= EPSILON) continue;
        const double normal_dot =
            (face_a.normal.x * face_b.normal.x +
             face_a.normal.y * face_b.normal.y) / (n1 * n2);
        if (normal_dot > std::cos(
                ROOM_REFLEX_NOISE_DEGREES * 3.14159265358979323846 / 180.0))
        {
            // Coplanar/seam edges bridge boundary continuity, but they
            // accumulate ZERO turning even when their 3D tilt changes.
            b = multiply(a, -1.0);
        }
        else if (normal_dot < -1.0 + 1.0e-8)
        {
            // Opposed normals are geometrically ambiguous as a Room corner.
            continue;
        }

        // Two separate shared edges may hit the same slice XY coordinate
        // (mesh seams). Keep the true face-pair incidences, not a synthetic
        // degree-two corner made by XY-only merging.
        corners.push_back({anchor, {a, b},
                           {first.face_index, second.face_index}});
    }
    return corners;
}
} // namespace

// Geometric candidate pruning in 3D: an existing safe route is never
// discarded unless a direct 3D chord has verified clearance and LOS.
bool redundant_corner_candidate_3d(
    const TriangleBvh& bvh, const Vec3& previous,
    const Vec3& middle, const Vec3& next, double tolerance
)
{
    const Vec3 chord = subtract(next, previous);
    const double chord_sq = length_squared(chord);
    if (chord_sq <= tolerance * tolerance) return false;
    const double t = dot(subtract(middle, previous), chord) / chord_sq;
    if (t <= 0.0 || t >= 1.0) return false;
    const Vec3 foot = add(previous, multiply(chord, t));
    const double deviation = length(subtract(middle, foot));
    const double clearance = std::min({
        bvh.nearest_distance(previous),
        bvh.nearest_distance(middle),
        bvh.nearest_distance(next)
    });
    if (!std::isfinite(clearance) || clearance <= tolerance * 2.0 ||
        deviation > std::max(tolerance,
                             2.0 * ROOM_SHORTCUT_MAX_DEVIATION_WIDTH_FRACTION * clearance))
        return false;
    if (!clear_path(bvh, previous, next, tolerance)) return false;
    const double min_allowed = std::max(
        tolerance * 2.0, ROOM_SHORTCUT_MIN_CLEARANCE_FRACTION * clearance
    );
    for (std::size_t step=1; step<8; ++step)
    {
        const Vec3 sample = add(previous, multiply(chord, step / 8.0));
        if (bvh.nearest_distance(sample) < min_allowed)
            return false;
    }
    return true;
}

std::vector<ReferencePoint> find_reference_points(
    const CellData& cell,
    const Vec3& state_point,
    double tolerance
)
{
    if (!(tolerance > 0.0) || !std::isfinite(tolerance)) return {};
    const double width = cell.bounds.maximum.x - cell.bounds.minimum.x;
    const double height = cell.bounds.maximum.y - cell.bounds.minimum.y;
    if (width <= tolerance || height <= tolerance) return {};
    const double short_span = std::min(width, height);
    const double long_span = std::max(width, height);
    const double geometry_epsilon = std::max(tolerance * 0.05, long_span * 1.0e-9);

    const std::vector<const Triangle*> triangles = triangle_pointers(cell);
    if (triangles.empty()) return {};
    TriangleBvh bvh(triangles);
    if (bvh.empty()) return {};

    std::vector<CornerVertex> vertices = topology_wall_corners(
        cell, tolerance, geometry_epsilon);
    const std::size_t vertex_count = vertices.size();
    if (vertex_count == 0) return {};

    // The XY component of each face's directed tangent measures ONLY
    // horizontal turning. The edge's Z slope contributes no angular turn.
    std::vector<double> signed_turn(vertex_count, 0.0);
    std::vector<Vec3> inward(vertex_count, Vec3{0, 0, 0});
    std::vector<bool> blocked(vertex_count, true);
    for (std::size_t i = 0; i < vertex_count; ++i)
    {
        const CornerVertex& corner = vertices[i];
        if (corner.rays.size() != 2) continue;
        const Vec3 bisector_sum = add(corner.rays[0], corner.rays[1]);
        if (length_squared(bisector_sum) <= EPSILON)
        {
            blocked[i] = false;
            continue; // Coplanar subdivision seam: zero turn.
        }
        const double cosine = std::max(-1.0, std::min(1.0,
            dot(corner.rays[0], corner.rays[1])));
        const double small_angle =
            std::acos(cosine) * 180.0 / 3.14159265358979323846;
        const Vec3 bisector = normalize(bisector_sum);
        const double probe = std::max(tolerance * 8.0, short_span * 0.01);
        const bool small_inside = bvh_inside(
            bvh, add(corner.point, multiply(bisector, probe)), tolerance);
        const bool reflex_inside = bvh_inside(
            bvh, subtract(corner.point, multiply(bisector, probe)), tolerance);
        if (small_inside == reflex_inside) continue;
        blocked[i] = false;
        const double turn = 180.0 - small_angle;
        if (turn > ROOM_REFLEX_NOISE_DEGREES)
        {
            signed_turn[i] = small_inside ? turn : -turn;
            if (!small_inside) inward[i] = multiply(bisector, -1.0);
        }
    }

    // Connected face strips define the order for cumulative turning.
    std::vector<std::vector<std::size_t>> neighbors(vertex_count);
    std::vector<std::vector<std::size_t>> face_corners(cell.faces.size());
    for (std::size_t i = 0; i < vertex_count; ++i)
        for (std::size_t face : vertices[i].incident_faces)
            face_corners[face].push_back(i);
    for (const std::vector<std::size_t>& indices : face_corners)
        for (std::size_t x = 0; x < indices.size(); ++x)
            for (std::size_t y = x + 1; y < indices.size(); ++y)
            {
                const std::size_t a = indices[x];
                const std::size_t b = indices[y];
                if (a == b) continue;
                if (std::find(neighbors[a].begin(), neighbors[a].end(), b) ==
                    neighbors[a].end()) neighbors[a].push_back(b);
                if (std::find(neighbors[b].begin(), neighbors[b].end(), a) ==
                    neighbors[b].end()) neighbors[b].push_back(a);
            }

    std::vector<std::size_t> selected;
    std::vector<std::vector<std::size_t>> selected_chains;
    std::vector<bool> visited(vertex_count, false);
    std::vector<bool> ordered(vertex_count, false);
    for (std::size_t seed=0; seed<vertex_count; ++seed)
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
            for (std::size_t neighbor : neighbors[v])
            {
                if (blocked[neighbor] || visited[neighbor]) continue;
                visited[neighbor] = true;
                stack.push_back(neighbor);
            }
        }
        std::size_t start = component.front();
        bool endpoint = false;
        bool simple = true;
        for (std::size_t v : component)
        {
            std::size_t degree = 0;
            for (std::size_t neighbor : neighbors[v])
                if (!blocked[neighbor]) ++degree;
            if (degree > 2) simple = false;
            if (degree <= 1 && !endpoint)
            {
                start = v;
                endpoint = true;
            }
        }
        if (!simple)
        {
            for (std::size_t v : component)
                if (signed_turn[v] <= -ROOM_CUMULATIVE_TURN_DEGREES)
                {
                    selected.push_back(v);
                    selected_chains.push_back({v});
                }
            continue;
        }
        std::vector<std::size_t> chain_candidates;
        const std::size_t none = vertex_count;
        std::size_t previous = none;
        std::size_t current = start;
        RoomSignedTurnAccumulator accumulator(ROOM_CUMULATIVE_TURN_DEGREES);
        for (std::size_t n=0; n<component.size(); ++n)
        {
            if (current == none || ordered[current]) break;
            ordered[current] = true;
            if (accumulator.advance(signed_turn[current]))
            {
                selected.push_back(current);
                chain_candidates.push_back(current);
            }
            std::size_t next = none;
            for (std::size_t neighbor : neighbors[current])
                if (neighbor != previous && !blocked[neighbor] && !ordered[neighbor])
                {
                    next = neighbor;
                    break;
                }
            previous = current;
            current = next;
        }
        if (endpoint)
        {
            if (!chain_candidates.empty())
                selected_chains.push_back(std::move(chain_candidates));
        }
        else
            for (std::size_t v : chain_candidates)
                selected_chains.push_back({v});
    }
    if (selected.empty()) return {};

    std::vector<ReferencePoint> points;
    const auto add_candidate = [&](const Vec3& candidate, ReferencePointKind kind)
    {
        if (points.size() >= MAX_ROOM_REFERENCE_DEBUG_POINTS ||
            !safe_reference(bvh, candidate, state_point, tolerance))
            return;
        const double duplicate = std::max(tolerance * 2.0, long_span * 1.0e-7);
        for (const ReferencePoint& existing : points)
            if (existing.kind == kind &&
                length_squared(subtract(existing.point, candidate)) <=
                    duplicate * duplicate)
                return;
        points.push_back({candidate, kind});
    };

    std::vector<std::optional<Vec3>> candidates(vertex_count);
    for (std::size_t i : selected)
    {
        const Vec3& anchor = vertices[i].point;
        const Vec3 direction = inward[i];
        if (length_squared(direction) <= EPSILON) continue;
        const double probe = std::max(tolerance * 8.0, short_span * 0.01);
        const Vec3 start = add(anchor, multiply(direction, probe));
        if (!bvh_inside(bvh, start, tolerance)) continue;
        const double from_start = bvh.first_ray_hit(start, direction, tolerance);
        if (!std::isfinite(from_start)) continue;
        const double span = probe + from_start;
        if (span <= tolerance * 2.0) continue;
        const Vec3 candidate = add(
            anchor, multiply(direction, ROOM_REFERENCE_INWARD_DISTANCE_FRACTION * span));
        if (safe_reference(bvh, candidate, state_point, tolerance) &&
            clear_path(bvh, start, candidate, tolerance))
            candidates[i] = candidate;
    }

    // Retain boundary endpoints, weakly linked chains and geometry that
    // cannot safely be replaced by a directly visible 3D shortcut.
    for (const std::vector<std::size_t>& chain : selected_chains)
    {
        std::vector<std::size_t> remaining;
        for (std::size_t v : chain)
            if (candidates[v]) remaining.push_back(v);
        std::size_t index = 1;
        while (index + 1 < remaining.size())
        {
            const std::size_t a = remaining[index - 1];
            const std::size_t b = remaining[index];
            const std::size_t d = remaining[index + 1];
            if (redundant_corner_candidate_3d(
                    bvh, *candidates[a], *candidates[b], *candidates[d],
                    tolerance))
            {
                candidates[b] = std::nullopt;
                remaining.erase(remaining.begin() +
                                static_cast<std::ptrdiff_t>(index));
                if (index > 1) --index;
            }
            else ++index;
        }
    }

    for (std::size_t v : selected)
        if (candidates[v])
            add_candidate(*candidates[v], ReferencePointKind::Corner);

    // Clustering uses scaled 3D inscribed-sphere radii rather than XY widths.
    const std::size_t original_count = points.size();
    std::vector<bool> merged_sources(original_count, false);
    if (original_count > 0)
    {
        std::vector<std::size_t> state_cluster;
        std::vector<std::vector<std::size_t>> clusters;
        const auto cluster_radius = [&](const Vec3& p) {
            return 2.0 * ROOM_LOCAL_WIDTH_CLUSTER_FRACTION *
                   std::max(0.0, bvh.nearest_distance(p) - tolerance);
        };
        const double state_radius = cluster_radius(state_point);
        std::vector<double> point_radii(original_count);
        for (std::size_t i=0; i<original_count; ++i)
            point_radii[i] = cluster_radius(points[i].point);

        const auto compatible = [&](std::size_t i,
                                    const std::vector<std::size_t>& members) {
            for (std::size_t member : members)
            {
                const double radius = std::min(point_radii[i], point_radii[member]);
                if (radius <= tolerance * 4.0 ||
                    length_squared(subtract(points[i].point, points[member].point)) >
                        radius * radius ||
                    !clear_path(bvh, points[i].point, points[member].point, tolerance))
                    return false;
            }
            return true;
        };

        for (std::size_t i=0; i<original_count; ++i)
        {
            const double radius = std::min(state_radius, point_radii[i]);
            if (radius > tolerance * 4.0 &&
                length_squared(subtract(points[i].point, state_point)) <=
                    radius * radius &&
                clear_path(bvh, points[i].point, state_point, tolerance) &&
                compatible(i, state_cluster))
            {
                state_cluster.push_back(i);
                continue;
            }
            bool added = false;
            for (auto& cluster : clusters)
                if (compatible(i, cluster))
                {
                    cluster.push_back(i);
                    added = true;
                    break;
                }
            if (!added) clusters.push_back({i});
        }
        if (!state_cluster.empty())
        {
            points.push_back({state_point, ReferencePointKind::Merged});
            for (std::size_t member : state_cluster)
                merged_sources[member] = true;
        }
        for (const auto& cluster : clusters)
        {
            if (cluster.size() < 2) continue;
            Vec3 center{0,0,0};
            for (std::size_t member : cluster)
                center = add(center, points[member].point);
            center = multiply(center, 1.0 / static_cast<double>(cluster.size()));
            bool valid = safe_reference(bvh, center, state_point, tolerance);
            for (std::size_t member : cluster)
                if (valid && !clear_path(bvh, points[member].point, center, tolerance))
                    valid = false;
            if (!valid) continue;
            add_candidate(center, ReferencePointKind::Merged);
            for (std::size_t member : cluster)
                merged_sources[member] = true;
        }
    }

    const std::size_t diagnostic_count = points.size();
    for (std::size_t i=0; i<diagnostic_count; ++i)
    {
        const bool unmerged_corner = i < original_count && !merged_sources[i];
        const bool non_state_center =
            points[i].kind == ReferencePointKind::Merged &&
            length_squared(subtract(points[i].point, state_point)) >
                tolerance * tolerance;
        if (!unmerged_corner && !non_state_center) continue;
        add_candidate(points[i].point, ReferencePointKind::Final);
    }
    return points;
}

// Build a diagnostic visibility graph from State and *final* reference nodes.
// Each XY disk is bounded by its nearest vertical wall. The local width
// approximation (2x nearest clearance) must be halved for an inscribed
// circle; the existing 0.15x reference clustering policy stays unchanged.
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
            // Single Face-Topology route: 1000 mm above the lowest
            // endpoint of every eligible wall/wall shared 3D Edge.
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
