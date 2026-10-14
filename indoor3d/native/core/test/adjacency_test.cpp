#include "adjacency_checker.h"
#include "cell_space_interior_point_locator.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <set>
#include <utility>
#include <vector>

namespace
{
using namespace IndoorGMLAdjacencyNative;

void require(bool condition, const char* message)
{
    if (!condition)
    {
        std::cerr << message << std::endl;
        std::exit(1);
    }
}

Aabb box(double min_x, double min_y, double min_z, double max_x, double max_y, double max_z)
{
    return Aabb{Vec3{min_x, min_y, min_z}, Vec3{max_x, max_y, max_z}};
}

Triangle triangle(Vec3 a, Vec3 b, Vec3 c)
{
    return Triangle{{a, b, c}};
}

FaceData face(Vec3 normal, std::initializer_list<Triangle> triangles)
{
    FaceData result;
    result.normal = normal;
    result.triangles = triangles;
    for (const Triangle& t : result.triangles)
        for (const Vec3& p : t.points)
            result.outer_points.push_back(p);
    return result;
}

FaceData shared_x_face(double x, double normal_x)
{
    const Vec3 p0{x, 0.0, 0.0};
    const Vec3 p1{x, 1.0, 0.0};
    const Vec3 p2{x, 1.0, 1.0};
    const Vec3 p3{x, 0.0, 1.0};

    FaceData result;
    result.normal = Vec3{normal_x, 0.0, 0.0};
    result.outer_points = {p0, p1, p2, p3};
    result.triangles = {
        triangle(p0, p1, p2),
        triangle(p0, p2, p3)
    };
    return result;
}

CellData unit_box_cell()
{
    const Vec3 p000{0,0,0}, p100{1,0,0}, p110{1,1,0}, p010{0,1,0};
    const Vec3 p001{0,0,1}, p101{1,0,1}, p111{1,1,1}, p011{0,1,1};
    CellData cell;
    cell.index = 0;
    cell.flags = CELL_FLAG_NEEDS_STATE | CELL_FLAG_ADJACENCY_TARGET;
    cell.bounds = box(0,0,0,1,1,1);
    cell.faces = {
        face({0,0,-1}, {triangle(p000,p110,p100), triangle(p000,p010,p110)}),
        face({0,0, 1}, {triangle(p001,p101,p111), triangle(p001,p111,p011)}),
        face({-1,0,0}, {triangle(p000,p001,p011), triangle(p000,p011,p010)}),
        face({ 1,0,0}, {triangle(p100,p110,p111), triangle(p100,p111,p101)}),
        face({0,-1,0}, {triangle(p000,p100,p101), triangle(p000,p101,p001)}),
        face({0, 1,0}, {triangle(p010,p011,p111), triangle(p010,p111,p110)})
    };
    return cell;
}

void add_rect_face(
    CellData& cell,
    Vec3 normal,
    Vec3 a,
    Vec3 b,
    Vec3 c,
    Vec3 d
)
{
    FaceData result;
    result.normal = normal;
    result.outer_points = {a,b,c,d};
    result.triangles = {triangle(a,b,c), triangle(a,c,d)};
    cell.faces.push_back(std::move(result));
}

CellData u_prism_cell()
{
    CellData cell;
    cell.index = 0;
    cell.flags = CELL_FLAG_NEEDS_STATE;
    cell.bounds = box(0,0,0,3,3,1);

    // Floor/top are three non-overlapping rectangles that tile the U cross-section.
    add_rect_face(cell,{0,0,-1},{0,0,0},{3,0,0},{3,1,0},{0,1,0});
    add_rect_face(cell,{0,0,-1},{0,1,0},{1,1,0},{1,3,0},{0,3,0});
    add_rect_face(cell,{0,0,-1},{2,1,0},{3,1,0},{3,3,0},{2,3,0});
    add_rect_face(cell,{0,0, 1},{0,0,1},{0,1,1},{3,1,1},{3,0,1});
    add_rect_face(cell,{0,0, 1},{0,1,1},{0,3,1},{1,3,1},{1,1,1});
    add_rect_face(cell,{0,0, 1},{2,1,1},{2,3,1},{3,3,1},{3,1,1});

    const std::array<Vec3,8> polygon{{
        {0,0,0},{3,0,0},{3,3,0},{2,3,0},
        {2,1,0},{1,1,0},{1,3,0},{0,3,0}
    }};
    for (std::size_t i=0; i<polygon.size(); ++i)
    {
        const Vec3 a = polygon[i];
        const Vec3 b = polygon[(i+1)%polygon.size()];
        const Vec3 a_top{a.x,a.y,1};
        const Vec3 b_top{b.x,b.y,1};
        const Vec3 edge{b.x-a.x,b.y-a.y,0};
        const Vec3 normal{edge.y,-edge.x,0};
        add_rect_face(cell,normal,a,b,b_top,a_top);
    }
    return cell;
}

// Rectangular prism with a centered inward notch on its upper boundary.
// Notch depths 0.25 and 0.5 produce reflex interior angles ~194deg and
// ~208deg, exercising the exact 200deg eligibility boundary.
CellData shallow_reflex_prism_cell(double notch_depth)
{
    CellData cell;
    cell.index = 0;
    cell.flags = CELL_FLAG_NEEDS_STATE;
    cell.category = CellSpaceCategory::Room;
    cell.bounds = box(0, 0, 0, 4, 4, 1);

    const std::array<Vec3, 5> polygon{{
        {0, 0, 0},
        {4, 0, 0},
        {4, 4, 0},
        {2, 4 - notch_depth, 0},
        {0, 4, 0}
    }};
    const std::array<std::array<std::size_t, 3>, 3> triangles{{
        {{0, 1, 3}},
        {{1, 2, 3}},
        {{0, 3, 4}}
    }};
    for (const auto& indices : triangles)
    {
        const Vec3 a = polygon[indices[0]];
        const Vec3 b = polygon[indices[1]];
        const Vec3 c = polygon[indices[2]];
        const Vec3 a_top{a.x, a.y, 1};
        const Vec3 b_top{b.x, b.y, 1};
        const Vec3 c_top{c.x, c.y, 1};
        cell.faces.push_back(face({0, 0, -1}, {triangle(a, c, b)}));
        cell.faces.push_back(face({0, 0, 1}, {triangle(a_top, b_top, c_top)}));
    }
    for (std::size_t i = 0; i < polygon.size(); ++i)
    {
        const Vec3 a = polygon[i];
        const Vec3 b = polygon[(i + 1) % polygon.size()];
        const Vec3 a_top{a.x, a.y, 1};
        const Vec3 b_top{b.x, b.y, 1};
        const Vec3 edge{b.x - a.x, b.y - a.y, 0};
        add_rect_face(
            cell, {edge.y, -edge.x, 0},
            a, b, b_top, a_top
        );
    }
    return cell;
}

void test_z_sweep_matches_bruteforce()
{
    std::vector<CellData> cells(5);
    cells[0].index = 0; cells[0].bounds = box(0, 0, 0, 2, 2, 2);
    cells[1].index = 1; cells[1].bounds = box(1, 1, 1, 3, 3, 3);
    cells[2].index = 2; cells[2].bounds = box(10, 10, 0, 11, 11, 2);
    cells[3].index = 3; cells[3].bounds = box(0, 0, 5, 2, 2, 6);
    cells[4].index = 4; cells[4].bounds = box(2, 0, 0, 4, 2, 2);

    const double tolerance = 0.001;
    std::set<std::pair<std::size_t, std::size_t>> brute;
    for (std::size_t first = 0; first < cells.size(); ++first)
        for (std::size_t second = first + 1; second < cells.size(); ++second)
            if (bounds_overlap(cells[first].bounds, cells[second].bounds, tolerance))
                brute.emplace(first, second);

    const std::vector<PairIndex> sweep = z_sweep_candidates(cells, tolerance);
    std::set<std::pair<std::size_t, std::size_t>> swept;
    for (const PairIndex& pair : sweep) swept.emplace(pair.first, pair.second);
    require(brute == swept, "Z sweep candidate set differs from brute-force AABB set");
}

void test_shared_face_analysis()
{
    CellData first;
    first.index = 0;
    first.bounds = box(0, 0, 0, 1, 1, 1);
    first.faces.push_back(shared_x_face(1.0, 1.0));

    CellData second;
    second.index = 1;
    second.bounds = box(1, 0, 0, 2, 1, 1);
    second.faces.push_back(shared_x_face(1.0, -1.0));

    const std::optional<PairResult> result = analyze_pair(first, second, 0.001, 0.000001);
    require(result.has_value(), "shared coplanar face was not classified adjacent");
    require(result->axis == 0, "shared X face did not produce X adjacency axis");
    require(result->candidates.size() == 1, "shared face should produce one waypoint candidate");
    const CandidateResult& candidate = result->candidates.front();
    require(std::abs(candidate.area - 1.0) <= 1.0e-9, "shared face area differs from expected");
    require(std::abs(candidate.centroid_x - 0.5) <= 1.0e-9, "shared face centroid first coordinate differs");
    require(std::abs(candidate.centroid_y - 0.5) <= 1.0e-9, "shared face centroid second coordinate differs");
}

void test_state_volume_centroid_on_box()
{
    CellData cell = unit_box_cell();
    StateSearchMetrics metrics;
    const std::optional<Vec3> point = find_state_point(cell, 0.001, &metrics);
    require(point.has_value(), "box State point was not found");
    require(std::abs(point->x - 0.5) < 1.0e-9, "box State x differs");
    require(std::abs(point->y - 0.5) < 1.0e-9, "box State y differs");
    require(std::abs(point->z - 0.5) < 1.0e-9, "box State z differs");
    require(metrics.volume_centroid_succeeded, "box should use volume centroid fast path");
    require(!metrics.used_bvh, "box should not build BVH");
}

void test_state_concave_u_uses_bvh_fallback()
{
    CellData cell = u_prism_cell();
    StateSearchMetrics metrics;
    const std::optional<Vec3> point = find_state_point(cell, 0.001, &metrics);
    require(point.has_value(), "concave U-prism State point was not found");
    require(metrics.used_bvh, "concave U-prism should require BVH fallback");
    const bool in_left = point->x > 0.0 && point->x < 1.0 && point->y > 0.0 && point->y < 3.0;
    const bool in_right = point->x > 2.0 && point->x < 3.0 && point->y > 0.0 && point->y < 3.0;
    const bool in_bottom = point->x > 0.0 && point->x < 3.0 && point->y > 0.0 && point->y < 1.0;
    require(in_left || in_right || in_bottom, "concave U-prism fallback point is outside");
}

void test_state_fixed_z()
{
    CellData cell = unit_box_cell();
    cell.flags |= CELL_FLAG_HAS_FIXED_Z;
    cell.fixed_z = 0.25;
    StateSearchMetrics metrics;
    const std::optional<Vec3> point = find_state_point(cell, 0.001, &metrics);
    require(point.has_value(), "fixed-Z State point was not found");
    require(std::abs(point->z - 0.25) < 1.0e-9, "fixed-Z State point did not preserve fixed Z");
}

void test_room_reference_points_share_state_height()
{
    CellData cell = unit_box_cell();
    cell.category = CellSpaceCategory::Room;
    cell.flags |= CELL_FLAG_HAS_FIXED_Z;
    cell.fixed_z = 0.25;

    const CellSpaceInteriorPointResult result =
        locate_cell_space_interior_points(cell, 0.001);
    require(result.state_point.has_value(), "Room State point was not found");
    // A square's half-ray candidates can coincide with State, and must then
    // be omitted instead of emitting duplicate reference points.
    require(
        result.reference_status == ReferencePointStatus::Succeeded,
        "Room reference generation status was not successful"
    );
    for (const ReferencePoint& reference : result.reference_points)
    {
        const Vec3& point = reference.point;
        require(
            std::abs(point.z - result.state_point->z) < 1.0e-9,
            "Room reference point does not share State height"
        );
        require(
            reference.kind == ReferencePointKind::Face ||
            reference.kind == ReferencePointKind::Corner ||
            reference.kind == ReferencePointKind::Merged ||
            reference.kind == ReferencePointKind::Final,
            "Room reference point kind is invalid"
        );
    }
}

void test_concave_room_reference_points()
{
    CellData cell = u_prism_cell();
    cell.category = CellSpaceCategory::Room;
    const CellSpaceInteriorPointResult result =
        locate_cell_space_interior_points(cell, 0.001);
    require(result.state_point.has_value(), "concave Room State point missing");
    require(!result.reference_points.empty(), "concave Room references missing");

    std::size_t face_count = 0;
    std::size_t corner_count = 0;
     std::size_t final_count = 0;
    std::vector<Vec3> raw_candidates;
    std::vector<Vec3> merge_centers;
    std::vector<Vec3> final_points;
    for (const ReferencePoint& reference : result.reference_points)
    {
        const Vec3& p = reference.point;
        const bool inside =
            (p.x > 0.0 && p.x < 1.0 && p.y > 0.0 && p.y < 3.0) ||
            (p.x > 2.0 && p.x < 3.0 && p.y > 0.0 && p.y < 3.0) ||
            (p.x > 0.0 && p.x < 3.0 && p.y > 0.0 && p.y < 1.0);
        require(inside, "concave Room reference fell outside footprint");
        if (reference.kind == ReferencePointKind::Face ||
            reference.kind == ReferencePointKind::Corner)
        {
            raw_candidates.push_back(p);
            if (reference.kind == ReferencePointKind::Face) ++face_count;
            else ++corner_count;
        }
        if (reference.kind == ReferencePointKind::Merged)
        {
             merge_centers.push_back(p);
        }
        if (reference.kind == ReferencePointKind::Final)
        {
            ++final_count;
            final_points.push_back(p);
        }
    }
    require(face_count > 0, "concave Room Face references missing");
    require(corner_count > 0, "concave Room Corner references missing");
    require(final_count > 0, "concave Room final references missing");
    require(final_count <= raw_candidates.size(),
            "final Room count exceeds original candidates");
    for (const Vec3& merged : merge_centers)
    {
        // A State-anchored cluster is represented by the existing State
        // rather than by an extra black Final reference point.
        const double sdx = merged.x - result.state_point->x;
        const double sdy = merged.y - result.state_point->y;
        if (sdx * sdx + sdy * sdy < 1.0e-10) continue;

        bool found = false;
        for (const Vec3& final_point : final_points)
        {
            const double dx = merged.x - final_point.x;
            const double dy = merged.y - final_point.y;
            if (dx * dx + dy * dy < 1.0e-10) found = true;
        }
        require(found, "accepted red cluster center is missing its black final point");
    }
}

void test_state_anchored_room_reference_cluster()
{
    CellData cell = u_prism_cell();
    cell.category = CellSpaceCategory::Room;

    // The left vertical corridor is 1.0 unit wide. Its Face midpoint
    // reference is (0.5, 1.5, 0.5), which can merge with this nearby State.
    const Vec3 state{0.55, 1.5, 0.5};
    const std::vector<ReferencePoint> references =
        find_reference_points(cell, state, 0.001);

    bool found_state_merge_marker = false;
    bool found_absorbed_source = false;
    bool found_absorbed_source_as_final = false;
    bool found_duplicate_state_final = false;
    for (const ReferencePoint& reference : references)
    {
        const Vec3& point = reference.point;
        const bool at_state =
            std::abs(point.x - state.x) < 1.0e-9 &&
            std::abs(point.y - state.y) < 1.0e-9 &&
            std::abs(point.z - state.z) < 1.0e-9;
        const bool at_wall_midpoint =
            std::abs(point.x - 0.5) < 1.0e-9 &&
            std::abs(point.y - 1.5) < 1.0e-9;

        if (reference.kind == ReferencePointKind::Merged && at_state)
            found_state_merge_marker = true;
        if ((reference.kind == ReferencePointKind::Face ||
             reference.kind == ReferencePointKind::Corner) && at_wall_midpoint)
            found_absorbed_source = true;
        if (reference.kind == ReferencePointKind::Final)
        {
            if (at_state) found_duplicate_state_final = true;
            if (at_wall_midpoint) found_absorbed_source_as_final = true;
        }
    }

    require(found_absorbed_source, "State merge fixture source is missing");
    require(found_state_merge_marker, "State cluster must use exact State position");
    require(!found_absorbed_source_as_final,
            "State-merged source must be excluded from final references");
    require(!found_duplicate_state_final,
            "State cluster must not create a duplicate black Final reference");
}

void test_convex_room_uses_state_only()
{
    CellData cell = unit_box_cell();
    cell.category = CellSpaceCategory::Room;
    cell.flags |= CELL_FLAG_HAS_FIXED_Z;
    cell.fixed_z = 0.25;

    const CellSpaceInteriorPointResult result =
        locate_cell_space_interior_points(cell, 0.001);
    require(result.state_point.has_value(), "convex Room State missing");
    require(result.reference_status == ReferencePointStatus::Succeeded,
            "convex Room reference evaluation must succeed");
    require(result.reference_points.empty(),
            "convex Room must use State alone (no reference or merged points)");

    // A noncentral State must not change convex eligibility.
    const std::vector<ReferencePoint> offcenter =
        find_reference_points(cell, {0.35, 0.42, 0.25}, 0.001);
    require(offcenter.empty(), "convex Room incorrectly generated references");
}

void test_room_reflex_threshold_200_degrees()
{
    const Vec3 state{2.0, 1.5, 0.5};
    const CellData shallow = shallow_reflex_prism_cell(0.25);
    const CellData deep = shallow_reflex_prism_cell(0.5);

    const std::vector<ReferencePoint> shallow_points =
        find_reference_points(shallow, state, 0.001);
    require(shallow_points.empty(),
            "reflex angle below 200deg must leave State as the only point");

    const std::vector<ReferencePoint> deep_points =
        find_reference_points(deep, state, 0.001);
    require(!deep_points.empty(),
            "reflex angle between 200deg and 225deg must generate references");
    bool found_eligible_corner = false;
    for (const ReferencePoint& point : deep_points)
    {
        if (point.kind == ReferencePointKind::Corner)
            found_eligible_corner = true;
    }
    require(found_eligible_corner,
            "200deg reflex threshold must produce a Corner reference candidate");
}

void test_non_room_reference_points_are_empty()
{
    const std::array<CellSpaceCategory,4> categories{{
        CellSpaceCategory::Stair,
        CellSpaceCategory::Elevator,
        CellSpaceCategory::Door,
        CellSpaceCategory::Window
    }};
    for (CellSpaceCategory category : categories)
    {
        CellData cell = unit_box_cell();
        cell.category = category;
        const CellSpaceInteriorPointResult result =
            locate_cell_space_interior_points(cell, 0.001);
        require(result.state_point.has_value(), "non-Room State point was not found");
        require(result.reference_points.empty(), "non-Room reference points must be empty");
        require(
            result.reference_status == ReferencePointStatus::NotAttempted,
            "non-Room reference generation must remain unattempted"
        );
    }
}
} // namespace

int main()
{
    test_z_sweep_matches_bruteforce();
    test_shared_face_analysis();
    test_state_volume_centroid_on_box();
    test_state_concave_u_uses_bvh_fallback();
    test_state_fixed_z();
    test_room_reference_points_share_state_height();
    test_convex_room_uses_state_only();
    test_room_reflex_threshold_200_degrees();
    test_concave_room_reference_points();
    test_state_anchored_room_reference_cluster();
    test_non_room_reference_points_are_empty();
    return 0;
}
