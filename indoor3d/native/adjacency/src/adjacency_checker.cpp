#include "adjacency_checker.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <tuple>
#include <utility>
#include <vector>

namespace
{
using namespace IndoorGMLAdjacencyNative;

constexpr double RUBY_GEOMETRY_EPSILON = 0.000001;

struct Point2
{
    double x = 0.0;
    double y = 0.0;
};

struct FaceOverlapAnalysis
{
    bool adjacent = false;
    bool has_waypoint = false;
    double waypoint_area = 0.0;
    double centroid_x = 0.0;
    double centroid_y = 0.0;
};

double dot(const Vec3& first, const Vec3& second)
{
    return first.x * second.x + first.y * second.y + first.z * second.z;
}

Vec3 subtract(const Vec3& first, const Vec3& second)
{
    return Vec3{first.x - second.x, first.y - second.y, first.z - second.z};
}

int dominant_axis(const Vec3& normal)
{
    int axis = 0;
    double maximum = std::abs(normal.x);
    if (std::abs(normal.y) > maximum)
    {
        axis = 1;
        maximum = std::abs(normal.y);
    }
    if (std::abs(normal.z) > maximum)
    {
        axis = 2;
    }
    return axis;
}

Point2 project(const Vec3& point, int axis)
{
    if (axis == 0)
    {
        return Point2{point.y, point.z};
    }
    if (axis == 1)
    {
        return Point2{point.x, point.z};
    }
    return Point2{point.x, point.y};
}

double polygon_area(const std::vector<Point2>& points)
{
    if (points.size() < 3)
    {
        return 0.0;
    }

    double twice_area = 0.0;
    for (std::size_t index = 0; index < points.size(); ++index)
    {
        const Point2& next = points[(index + 1) % points.size()];
        twice_area += points[index].x * next.y - next.x * points[index].y;
    }
    return twice_area / 2.0;
}

double orientation(const Point2& first, const Point2& second, const Point2& third)
{
    return ((second.x - first.x) * (third.y - first.y)) -
           ((second.y - first.y) * (third.x - first.x));
}

bool inside_clip_edge(
    const Point2& point,
    const Point2& edge_start,
    const Point2& edge_end,
    double clip_sign
)
{
    return clip_sign * orientation(edge_start, edge_end, point) >= -RUBY_GEOMETRY_EPSILON;
}

Point2 line_intersection(
    const Point2& line1_start,
    const Point2& line1_end,
    const Point2& line2_start,
    const Point2& line2_end
)
{
    const double denominator =
        ((line1_start.x - line1_end.x) * (line2_start.y - line2_end.y)) -
        ((line1_start.y - line1_end.y) * (line2_start.x - line2_end.x));
    if (std::abs(denominator) <= RUBY_GEOMETRY_EPSILON)
    {
        return line1_end;
    }

    const double cross1 = (line1_start.x * line1_end.y) - (line1_start.y * line1_end.x);
    const double cross2 = (line2_start.x * line2_end.y) - (line2_start.y * line2_end.x);
    return Point2{
        ((cross1 * (line2_start.x - line2_end.x)) -
         ((line1_start.x - line1_end.x) * cross2)) /
            denominator,
        ((cross1 * (line2_start.y - line2_end.y)) -
         ((line1_start.y - line1_end.y) * cross2)) /
            denominator
    };
}

std::vector<Point2> clip_polygon(
    const std::vector<Point2>& subject_polygon,
    const std::vector<Point2>& clip_polygon_points
)
{
    if (subject_polygon.empty() || clip_polygon_points.size() < 3)
    {
        return {};
    }

    const double clip_sign = polygon_area(clip_polygon_points) < 0.0 ? -1.0 : 1.0;
    std::vector<Point2> output = subject_polygon;
    for (std::size_t edge_index = 0; edge_index < clip_polygon_points.size(); ++edge_index)
    {
        const Point2 clip_start = clip_polygon_points[edge_index];
        const Point2 clip_end = clip_polygon_points[(edge_index + 1) % clip_polygon_points.size()];
        const std::vector<Point2> input = output;
        output.clear();
        if (input.empty())
        {
            break;
        }

        Point2 previous = input.back();
        for (const Point2& current : input)
        {
            const bool current_inside = inside_clip_edge(current, clip_start, clip_end, clip_sign);
            const bool previous_inside = inside_clip_edge(previous, clip_start, clip_end, clip_sign);
            if (current_inside)
            {
                if (!previous_inside)
                {
                    output.push_back(line_intersection(previous, current, clip_start, clip_end));
                }
                output.push_back(current);
            }
            else if (previous_inside)
            {
                output.push_back(line_intersection(previous, current, clip_start, clip_end));
            }
            previous = current;
        }
    }
    return output;
}

Point2 polygon_centroid(const std::vector<Point2>& points)
{
    double area_factor = 0.0;
    double centroid_x = 0.0;
    double centroid_y = 0.0;
    for (std::size_t index = 0; index < points.size(); ++index)
    {
        const Point2& point = points[index];
        const Point2& next = points[(index + 1) % points.size()];
        const double cross = (point.x * next.y) - (next.x * point.y);
        area_factor += cross;
        centroid_x += (point.x + next.x) * cross;
        centroid_y += (point.y + next.y) * cross;
    }

    if (std::abs(area_factor) <= RUBY_GEOMETRY_EPSILON)
    {
        double sum_x = 0.0;
        double sum_y = 0.0;
        for (const Point2& point : points)
        {
            sum_x += point.x;
            sum_y += point.y;
        }
        return Point2{
            sum_x / static_cast<double>(points.size()),
            sum_y / static_cast<double>(points.size())
        };
    }

    return Point2{
        centroid_x / (3.0 * area_factor),
        centroid_y / (3.0 * area_factor)
    };
}

bool normals_opposite(const Vec3& first, const Vec3& second, double normal_tolerance)
{
    return std::abs(dot(first, second) + 1.0) <= normal_tolerance;
}

bool points_on_plane(
    const std::vector<Vec3>& points,
    const Vec3& normal,
    const Vec3& plane_point,
    double length_tolerance
)
{
    for (const Vec3& point : points)
    {
        if (std::abs(dot(subtract(point, plane_point), normal)) > length_tolerance)
        {
            return false;
        }
    }
    return true;
}

std::vector<Point2> projected_triangle(const Triangle& triangle, int axis)
{
    std::vector<Point2> points;
    points.reserve(3);
    for (const Vec3& point : triangle.points)
    {
        points.push_back(project(point, axis));
    }
    return points;
}

FaceOverlapAnalysis analyze_face_overlap(
    const FaceData& first,
    const FaceData& second,
    double area_tolerance
)
{
    FaceOverlapAnalysis result;
    if (first.triangles.empty() || second.triangles.empty())
    {
        return result;
    }

    const int axis = dominant_axis(first.normal);
    double adjacent_area = 0.0;
    double waypoint_area = 0.0;
    double weighted_x = 0.0;
    double weighted_y = 0.0;

    for (const Triangle& first_triangle : first.triangles)
    {
        const std::vector<Point2> first_polygon = projected_triangle(first_triangle, axis);
        for (const Triangle& second_triangle : second.triangles)
        {
            const std::vector<Point2> second_polygon = projected_triangle(second_triangle, axis);
            const std::vector<Point2> overlap = clip_polygon(first_polygon, second_polygon);
            const double area = std::abs(polygon_area(overlap));
            adjacent_area += area;

            if (overlap.size() < 3 || area <= area_tolerance)
            {
                continue;
            }

            const Point2 centroid = polygon_centroid(overlap);
            weighted_x += centroid.x * area;
            weighted_y += centroid.y * area;
            waypoint_area += area;
        }
    }

    result.adjacent = adjacent_area > area_tolerance;
    if (waypoint_area > area_tolerance)
    {
        result.has_waypoint = true;
        result.waypoint_area = waypoint_area;
        result.centroid_x = weighted_x / waypoint_area;
        result.centroid_y = weighted_y / waypoint_area;
    }
    return result;
}
} // namespace

namespace IndoorGMLAdjacencyNative
{
bool bounds_overlap(const Aabb& first, const Aabb& second, double tolerance)
{
    return std::max(first.minimum.x, second.minimum.x) <=
               std::min(first.maximum.x, second.maximum.x) + tolerance &&
           std::max(first.minimum.y, second.minimum.y) <=
               std::min(first.maximum.y, second.maximum.y) + tolerance &&
           std::max(first.minimum.z, second.minimum.z) <=
               std::min(first.maximum.z, second.maximum.z) + tolerance;
}

std::vector<PairIndex> z_sweep_candidates(
    const std::vector<CellData>& cells,
    double tolerance
)
{
    std::vector<std::size_t> order(cells.size());
    for (std::size_t index = 0; index < cells.size(); ++index)
    {
        order[index] = index;
    }
    std::stable_sort(order.begin(), order.end(), [&cells](std::size_t first, std::size_t second) {
        if (cells[first].bounds.minimum.z != cells[second].bounds.minimum.z)
        {
            return cells[first].bounds.minimum.z < cells[second].bounds.minimum.z;
        }
        return first < second;
    });

    std::vector<std::size_t> active;
    std::vector<PairIndex> candidates;
    for (const std::size_t current_index : order)
    {
        const double current_min_z = cells[current_index].bounds.minimum.z;
        active.erase(
            std::remove_if(
                active.begin(),
                active.end(),
                [&](std::size_t other_index) {
                    return cells[other_index].bounds.maximum.z + tolerance < current_min_z;
                }
            ),
            active.end()
        );

        for (const std::size_t other_index : active)
        {
            if (!bounds_overlap(cells[other_index].bounds, cells[current_index].bounds, tolerance))
            {
                continue;
            }
            const std::size_t first = std::min(other_index, current_index);
            const std::size_t second = std::max(other_index, current_index);
            candidates.push_back(PairIndex{first, second});
        }
        active.push_back(current_index);
    }

    std::sort(candidates.begin(), candidates.end(), [](const PairIndex& first, const PairIndex& second) {
        return std::tie(first.first, first.second) < std::tie(second.first, second.second);
    });
    candidates.erase(
        std::unique(candidates.begin(), candidates.end(), [](const PairIndex& first, const PairIndex& second) {
            return first.first == second.first && first.second == second.second;
        }),
        candidates.end()
    );
    return candidates;
}

std::optional<PairResult> analyze_pair(
    const CellData& first,
    const CellData& second,
    double length_tolerance,
    double normal_tolerance
)
{
    if (!bounds_overlap(first.bounds, second.bounds, length_tolerance))
    {
        return std::nullopt;
    }

    const double area_tolerance = length_tolerance * length_tolerance;
    bool adjacent = false;
    int pair_axis = -1;
    PairResult result;
    result.cell1_index = std::min(first.index, second.index);
    result.cell2_index = std::max(first.index, second.index);

    for (std::size_t first_face_index = 0; first_face_index < first.faces.size(); ++first_face_index)
    {
        const FaceData& first_face = first.faces[first_face_index];
        if (first_face.outer_points.empty())
        {
            continue;
        }

        for (std::size_t second_face_index = 0; second_face_index < second.faces.size(); ++second_face_index)
        {
            const FaceData& second_face = second.faces[second_face_index];
            if (!normals_opposite(first_face.normal, second_face.normal, normal_tolerance))
            {
                continue;
            }
            if (!points_on_plane(
                    second_face.outer_points,
                    first_face.normal,
                    first_face.outer_points.front(),
                    length_tolerance
                ))
            {
                continue;
            }

            const FaceOverlapAnalysis overlap =
                analyze_face_overlap(first_face, second_face, area_tolerance);
            if (!overlap.adjacent)
            {
                continue;
            }

            adjacent = true;
            const int face_axis = dominant_axis(first_face.normal);
            if (pair_axis < 0)
            {
                pair_axis = face_axis;
            }

            if (overlap.has_waypoint)
            {
                result.candidates.push_back(CandidateResult{
                    first_face_index,
                    second_face_index,
                    face_axis,
                    overlap.waypoint_area,
                    overlap.centroid_x,
                    overlap.centroid_y
                });
            }
        }
    }

    if (!adjacent || pair_axis < 0)
    {
        return std::nullopt;
    }
    result.axis = pair_axis;
    return result;
}
} // namespace IndoorGMLAdjacencyNative
