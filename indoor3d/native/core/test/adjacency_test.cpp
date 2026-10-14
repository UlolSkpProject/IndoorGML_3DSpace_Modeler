#include "adjacency_checker.h"
#include "cell_space_interior_point_locator.h"

#include <algorithm>
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

// A concave arc with two successive ~11-degree reflex turns.
// Each corner alone would be ignored by the old 200-degree cutoff.
CellData gradual_reflex_arc()
{
    CellData cell;
    cell.index = 0;
    cell.category = CellSpaceCategory::Room;
    cell.flags = CELL_FLAG_NEEDS_STATE;
    cell.bounds = box(0,0,0,6,6,1);
    const std::vector<Vec3> ring{
        {0,0,0},{6,0,0},{6,6,0},{5,5.5,0},
        {4,5.2,0},{3,5.1,0},{2,5,0},{0,5,0}
    };
    const Vec3 center{3,2,0};
    for (std::size_t i = 0; i < ring.size(); ++i)
    {
        const Vec3 a = ring[i];
        const Vec3 b = ring[(i+1)%ring.size()];
        const Vec3 a_top{a.x,a.y,1};
        const Vec3 b_top{b.x,b.y,1};
        const Vec3 center_top{center.x,center.y,1};
        cell.faces.push_back(face({0,0,-1},{triangle(center,b,a)}));
        cell.faces.push_back(face({0,0, 1},{triangle(center_top,a_top,b_top)}));
        const Vec3 edge{b.x-a.x,b.y-a.y,0};
        add_rect_face(cell,{edge.y,-edge.x,0},a,b,b_top,a_top);
    }
    return cell;
}

// Wide star-shaped polygon with a gently concave upper wall consisting of
// many small reflex turns. Tests that the simplifier retains valid candidates
// without eliminating an entire navigable curve.
CellData smooth_concave_wall_room()
{
    CellData cell;
    cell.index = 0;
    cell.category = CellSpaceCategory::Room;
    cell.flags = CELL_FLAG_NEEDS_STATE;
    cell.bounds = box(0, 0, 0, 40, 40, 1);
    std::vector<Vec3> outline{{0,0,0},{40,0,0}};
    for (int x = 40; x >= 0; --x)
    {
        const double distance = static_cast<double>(x - 20);
        outline.push_back({static_cast<double>(x),
                           20.0 + 0.05 * distance * distance, 0.0});
    }
    const Vec3 floor_center{20,1,0};
    const Vec3 ceiling_center{20,1,1};
    for (std::size_t i = 0; i < outline.size(); ++i)
    {
        const Vec3 first = outline[i];
        const Vec3 second = outline[(i+1) % outline.size()];
        const Vec3 first_top{first.x, first.y, 1};
        const Vec3 second_top{second.x, second.y, 1};
        cell.faces.push_back(face(
            {0,0,-1}, {triangle(floor_center, second, first)}
        ));
        cell.faces.push_back(face(
            {0,0,1}, {triangle(ceiling_center, first_top, second_top)}
        ));
        const Vec3 side{second.x-first.x,second.y-first.y,0};
        add_rect_face(cell,{side.y,-side.x,0},
                      first,second,second_top,first_top);
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
    // A convex Room requires no Reference Points: its State is sufficient.
    require(
        result.reference_status == ReferencePointStatus::Succeeded,
        "Room reference generation status was not successful"
    );
    require(result.reference_points.empty(),
            "convex Room must contain only its State");
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
        require(reference.kind != ReferencePointKind::Face,
                "green Face references must never be generated");
        if (reference.kind == ReferencePointKind::Corner)
        {
            raw_candidates.push_back(p);
            ++corner_count;
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
    require(corner_count > 0, "concave Room must produce reflex Corner candidates");
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
    CellData cell = shallow_reflex_prism_cell(0.5);

    // Compute a purple Corner position using the same solid with a State far
    // from the reflex corner. The candidate's position depends on geometry,
    // not on State XY (only its Z).
    const Vec3 distant_state{2.0, 0.5, 0.5};
    const std::vector<ReferencePoint> initial =
        find_reference_points(cell, distant_state, 0.001);

    std::optional<Vec3> corner;
    for (const ReferencePoint& reference : initial)
    {
        require(reference.kind != ReferencePointKind::Face,
                "State fixture unexpectedly generated green Face points");
        if (reference.kind == ReferencePointKind::Corner)
            corner = reference.point;
    }
    require(corner.has_value(), "State merge fixture Corner is missing");

    // Bring the State near the candidate. The resulting cluster must retain
    // the exact State position and suppress a duplicate final black point.
    const Vec3 state{corner->x + 0.05, corner->y, corner->z};
    const std::vector<ReferencePoint> references =
        find_reference_points(cell, state, 0.001);

    bool found_state_merge_marker = false;
    bool found_absorbed_corner = false;
    bool found_absorbed_as_final = false;
    bool found_duplicate_state_final = false;
    for (const ReferencePoint& reference : references)
    {
        const Vec3& point = reference.point;
        const bool at_state =
            std::abs(point.x - state.x) < 1.0e-9 &&
            std::abs(point.y - state.y) < 1.0e-9 &&
            std::abs(point.z - state.z) < 1.0e-9;
        const bool at_corner =
            std::abs(point.x - corner->x) < 1.0e-9 &&
            std::abs(point.y - corner->y) < 1.0e-9;
        require(reference.kind != ReferencePointKind::Face,
                "green Face candidate must not be emitted");
        if (reference.kind == ReferencePointKind::Merged && at_state)
            found_state_merge_marker = true;
        if (reference.kind == ReferencePointKind::Corner && at_corner)
            found_absorbed_corner = true;
        if (reference.kind == ReferencePointKind::Final)
        {
            if (at_state) found_duplicate_state_final = true;
            if (at_corner) found_absorbed_as_final = true;
        }
    }

    require(found_absorbed_corner, "State merge must retain purple Corner diagnostic");
    require(found_state_merge_marker, "State cluster must preserve exact State coordinates");
    require(!found_absorbed_as_final,
            "State-merged Corner must be absent from final references");
    require(!found_duplicate_state_final,
            "State cluster must not create duplicate black Final reference");
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

void test_signed_corner_turn_accumulation()
{
    // Reflex negative, convex positive, straight parallel walls zero.
    RoomSignedTurnAccumulator run(15.0);
    require(!run.advance(0.0) && run.accumulated_degrees() == 0.0,
            "parallel faces must yield zero signed curvature");
    require(!run.advance(-9.0), "first sub-threshold reflex must not emit");
    require(!run.advance(+4.0), "convex offset must not immediately terminate the run");
    require(std::abs(run.accumulated_degrees() + 5.0) < 1.0e-9,
            "convex turn must offset the accumulated reflex magnitude");
    require(!run.advance(-8.0), "net -13 degrees must not emit");
    require(run.advance(-2.0), "net -15 degrees must emit a reflex point");
    require(run.accumulated_degrees() == 0.0,
            "accumulation must reset after a reference is emitted");

    require(!run.advance(-12.0), "new reflex run must begin below threshold");
    require(!run.advance(+12.0), "zero-net bend must not emit");
    require(run.accumulated_degrees() == 0.0,
            "accumulation must reset once the net bend is nonnegative");
    require(!run.advance(+25.0), "standalone convex bend must never emit");
    require(run.accumulated_degrees() == 0.0,
            "standalone convex turns must not be carried into a reflex run");
    require(!run.advance(-14.0), "negative net turn below threshold must wait");
    require(run.advance(-1.0), "subsequent net -15 degrees must emit");

    RoomSignedTurnAccumulator cancellation(15.0);
    require(!cancellation.advance(-10.0), "short reflex run expected");
    require(!cancellation.advance(+15.0), "convex overshoot must reset the run");
    require(!cancellation.advance(-9.0),
            "old reflex deficit must not survive a convex net positive turn");
    require(cancellation.advance(-6.0), "new -15 degree run must emit");
}

void test_room_reflex_threshold_15_degree_turn()
{
    const Vec3 state{2.0, 1.5, 0.5};
    // Inner angles: ~194.25deg (14.25deg turn), ~197.06deg
    // (17.06deg turn), and ~208.07deg (28.07deg turn).
    const CellData shallow = shallow_reflex_prism_cell(0.25);
    const CellData medium = shallow_reflex_prism_cell(0.30);
    const CellData deep = shallow_reflex_prism_cell(0.5);

    require(find_reference_points(shallow, state, 0.001).empty(),
            "a single reflex turn below 15deg must not generate a reference");

    const std::vector<ReferencePoint> medium_points =
        find_reference_points(medium, state, 0.001);
    const std::vector<ReferencePoint> deep_points =
        find_reference_points(deep, state, 0.001);

    for (const auto* points : {&medium_points, &deep_points})
    {
        bool found_corner = false;
        for (const ReferencePoint& point : *points)
        {
            require(point.kind != ReferencePointKind::Face,
                    "green Face candidates must remain disabled");
            if (point.kind == ReferencePointKind::Corner)
                found_corner = true;
        }
        require(found_corner,
                "a single reflex turn above 15deg must generate a purple reference");
    }
}

void test_cumulative_reflex_turn_on_curved_wall()
{
    const CellData cell = gradual_reflex_arc();
    const std::vector<ReferencePoint> points =
        find_reference_points(cell, {3,2,0.5}, 0.001);
    bool has_corner = false;
    for (const ReferencePoint& point : points)
    {
        require(point.kind != ReferencePointKind::Face,
                "cumulative curve must not generate Face midpoint candidates");
        if (point.kind == ReferencePointKind::Corner) has_corner = true;
    }
    require(has_corner,
            "multiple 180-200 degree reflex corners must generate a purple reference");
}

void test_local_width_limits_cluster_radius()
{
    const CellData cell = shallow_reflex_prism_cell(0.5);
    const std::vector<ReferencePoint> initial =
        find_reference_points(cell, {2,0.5,0.5}, 0.001);
    std::optional<Vec3> corner;
    for (const ReferencePoint& p : initial)
        if (p.kind == ReferencePointKind::Corner) corner = p.point;
    require(corner.has_value(), "local-width fixture Corner missing");

    // Previously 0.18 * AABB short side (4) = 0.72, so 0.6 merged.
    // The narrower local cross-section now sets a stricter limit.
    const Vec3 state{corner->x+0.6, corner->y, corner->z};
    const std::vector<ReferencePoint> points =
        find_reference_points(cell, state, 0.001);
    bool has_final_corner = false;
    bool merged_with_state = false;
    for (const ReferencePoint& p : points)
    {
        if (p.kind == ReferencePointKind::Final &&
            std::abs(p.point.x-corner->x) < 1.0e-9 &&
            std::abs(p.point.y-corner->y) < 1.0e-9)
            has_final_corner = true;
        if (p.kind == ReferencePointKind::Merged &&
            std::abs(p.point.x-state.x) < 1.0e-9 &&
            std::abs(p.point.y-state.y) < 1.0e-9)
            merged_with_state = true;
    }
    require(has_final_corner, "local-radius test lost unmerged final Corner");
    require(!merged_with_state, "local-radius test incorrectly absorbed Corner into State");
}

void test_smooth_concave_wall_retains_safe_navigation_candidates()
{
    const CellData room = smooth_concave_wall_room();
    const Vec3 state{20,6,0.5};
    const std::vector<ReferencePoint> points =
        find_reference_points(room,state,0.001);

    std::size_t corner_count = 0;
    for (const ReferencePoint& item : points)
    {
        const Vec3& point = item.point;
        // All debug and final points must remain inside the footprint.
        const double dx = point.x - 20.0;
        require(point.x > 0.0 && point.x < 40.0 &&
                point.y > 0.0 && point.y < 20.0 + 0.05 * dx * dx,
                "smooth Room reference escaped its interior after simplification");
        require(item.kind != ReferencePointKind::Face,
                "simplification reintroduced green Face candidates");
        if (item.kind == ReferencePointKind::Corner) ++corner_count;
    }
    require(corner_count >= 2,
            "smooth concave wall lost the navigation candidates along its curve");
    // A 126deg gradual turn needs roughly eight 15deg seeds. The simplifier
    // must not generate further nodes or duplicate source candidates.
    require(corner_count <= 8,
            "smooth concave wall produced excessive purple candidates");
}

void test_room_visibility_graph_circle_overlap_and_blocked_los()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const Vec3 state{0.5, 0.5, 0.5};
    const std::vector<ReferencePoint> points{
        {{0.2, 0.5, 0.5}, ReferencePointKind::Final},
        {{0.8, 0.5, 0.5}, ReferencePointKind::Final},
        {{0.3, 0.3, 0.5}, ReferencePointKind::Corner}
    };
    const ReferenceGraphDebug graph =
        build_room_reference_visibility_graph(room, state, points, 0.001);
    require(graph.nodes.size() == 3,
            "graph must contain State and Final refs, not diagnostic candidates");
    require(graph.edges.size() == 2,
            "bounded circles should connect State to each Final, not each other");
    require(std::abs(graph.nodes[0].radius - 0.499) < 1.0e-9,
            "State disk radius must be nearest XY wall clearance minus tolerance");
    require(std::abs(graph.nodes[1].radius - 0.199) < 1.0e-9,
            "Final disk radius must not cross the nearest XY wall");
    require(graph.edges[0].first == 0 && graph.edges[0].second == 1 &&
            graph.edges[1].first == 0 && graph.edges[1].second == 2,
            "bounded-circle overlap should produce only State-to-Final edges");
    for (const ReferenceGraphNode& node : graph.nodes)
    {
        const double p[] = {
            node.point.x, 1.0 - node.point.x,
            node.point.y, 1.0 - node.point.y
        };
        for (double wall_distance : p)
            require(node.radius <= wall_distance,
                    "inscribed XY disk must not cross any Room wall");
    }
    for (const ReferenceGraphEdge& edge : graph.edges)
        require(edge.first < edge.second && edge.second < graph.nodes.size(),
                "graph edges must reference valid nodes");

    const CellData u = u_prism_cell();
    const std::vector<ReferencePoint> blocked_points{
        {{0.5, 2.5, 0.5}, ReferencePointKind::Final},
        {{2.5, 2.5, 0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug blocked =
        build_room_reference_visibility_graph(u, {1.5, 0.5, 0.5},
                                               blocked_points, 0.001);
    require(blocked.nodes.size() == 3, "U room must preserve both Final nodes");
    for (const ReferenceGraphEdge& edge : blocked.edges)
        require(!(edge.first == 1 && edge.second == 2),
                "overlapping circle centers must not connect across a Room wall");
}

void test_triangle_loop_candidates_are_validated_in_native()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const Vec3 state{0.5, 0.5, 0.5};
    const std::vector<ReferencePoint> points{
        {{0.3, 0.3, 0.5}, ReferencePointKind::Final},
        {{0.7, 0.3, 0.5}, ReferencePointKind::Final},
        {{0.5, 0.7, 0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug graph =
        build_room_reference_visibility_graph(room, state, points, 0.001);
    require(graph.nodes.size() == 4, "Native loop fixture lost Final nodes");
    bool found = false;
    for (const ReferenceLoopCollapseCandidate& candidate : graph.loop_candidates)
    {
        if (candidate.vertices != std::vector<std::size_t>{1, 2, 3})
            continue;
        require(std::abs(candidate.representative.point.x - 0.5) < 1.0e-9,
                "triangle centroid X incorrect");
        require(std::abs(candidate.representative.point.y - (1.3 / 3.0)) < 1.0e-9,
                "triangle centroid Y incorrect");
        require(candidate.representative.radius > 0.0,
                "validated centroid must have positive clearance");
        require(std::find(candidate.visible_neighbors.begin(),
                          candidate.visible_neighbors.end(), 0) !=
                    candidate.visible_neighbors.end(),
                "candidate center must verify LOS to external State");
        found = true;
    }
    require(found, "valid triangle loop must yield one Native representative");

    // A U-shaped Room must never validate the wall-crossing segment
    // between these two Final nodes, hence cannot offer such a triangle.
    CellData u = u_prism_cell();
    const std::vector<ReferencePoint> other{
        {{0.5, 2.5, 0.5}, ReferencePointKind::Final},
        {{2.5, 2.5, 0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug separated =
        build_room_reference_visibility_graph(u, {1.5, 0.5, 0.5}, other, 0.001);
    require(separated.loop_candidates.empty(),
            "blocked Room may not produce a wall-crossing loop representative");
}

void test_triangle_loop_new_edge_can_cross_non_overlapping_circles()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;

    // The first three Final references form a triangle close to the
    // lower-left corner. Final node 4 overlaps node 2's disk, but NOT
    // the centroid's disk. Direct LOS to node 4 is unobstructed.
    const Vec3 state{0.9, 0.9, 0.5};
    const std::vector<ReferencePoint> points{
        {{0.2, 0.2, 0.5}, ReferencePointKind::Final},
        {{0.4, 0.2, 0.5}, ReferencePointKind::Final},
        {{0.2, 0.4, 0.5}, ReferencePointKind::Final},
        {{0.78, 0.25, 0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug graph =
        build_room_reference_visibility_graph(room, state, points, 0.001);
    require(graph.nodes.size() == 5, "test Room lost a graph node");

    const auto has_original_edge = [&](std::size_t a, std::size_t b) {
        return std::any_of(graph.edges.begin(), graph.edges.end(),
            [&](const ReferenceGraphEdge& edge) {
                return edge.first == a && edge.second == b;
            });
    };
    require(has_original_edge(1, 2) &&
            has_original_edge(1, 3) &&
            has_original_edge(2, 3),
            "fixture's three candidate vertices must form a cycle");
    require(has_original_edge(2, 4),
            "fixture's external neighbor must be connected to the cycle");

    bool found = false;
    for (const ReferenceLoopCollapseCandidate& candidate : graph.loop_candidates)
    {
        if (candidate.vertices != std::vector<std::size_t>{1, 2, 3})
            continue;

        const double separation = std::sqrt(
            (candidate.representative.point.x - graph.nodes[4].point.x) *
            (candidate.representative.point.x - graph.nodes[4].point.x) +
            (candidate.representative.point.y - graph.nodes[4].point.y) *
            (candidate.representative.point.y - graph.nodes[4].point.y)
        );
        require(separation >
                candidate.representative.radius + graph.nodes[4].radius,
                "fixture must have non-overlapping centroid/external circles");
        require(std::find(candidate.visible_neighbors.begin(),
                          candidate.visible_neighbors.end(), 4) !=
                    candidate.visible_neighbors.end(),
                "Native must validate a new collapse edge by LOS without circle overlap");
        found = true;
    }
    require(found, "Native should preserve non-overlap triangle candidate");
}

void test_triangle_loop_new_edges_still_reject_wall_crossings()
{
    CellData room = u_prism_cell();
    room.category = CellSpaceCategory::Room;

    // Triangle in the left arm, other Final reference in the right arm.
    // LOS between their centers crosses the Room's empty central notch.
    const std::vector<ReferencePoint> points{
        {{0.35, 2.1, 0.5}, ReferencePointKind::Final},
        {{0.65, 2.1, 0.5}, ReferencePointKind::Final},
        {{0.5, 2.45, 0.5}, ReferencePointKind::Final},
        {{2.5, 2.2, 0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug graph =
        build_room_reference_visibility_graph(room, {1.5, 0.5, 0.5}, points, 0.001);
    require(graph.nodes.size() == 5, "U Room lost a graph node");
    bool found = false;
    for (const ReferenceLoopCollapseCandidate& candidate : graph.loop_candidates)
    {
        if (candidate.vertices != std::vector<std::size_t>{1, 2, 3})
            continue;
        found = true;
        require(std::find(candidate.visible_neighbors.begin(),
                          candidate.visible_neighbors.end(), 4) ==
                    candidate.visible_neighbors.end(),
                "Native must reject new edges crossing a Room wall");
    }
    require(found, "U Room should retain a valid left-arm triangle candidate");
}

void test_four_cycle_native_centroid_and_los_candidate()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    // Neighbor disks overlap; diagonals do not. Thus four Final nodes
    // form an induced 4-cycle rather than four triangles.
    const Vec3 state{0.1, 0.1, 0.5};
    const std::vector<ReferencePoint> points{
        {{0.27, 0.27, 0.5}, ReferencePointKind::Final},
        {{0.73, 0.27, 0.5}, ReferencePointKind::Final},
        {{0.73, 0.73, 0.5}, ReferencePointKind::Final},
        {{0.27, 0.73, 0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug graph =
        build_room_reference_visibility_graph(room, state, points, 0.001);
    require(graph.nodes.size() == 5, "4-cycle fixture lost graph vertices");
    const auto linked = [&](std::size_t a, std::size_t b) {
        for (const ReferenceGraphEdge& edge : graph.edges)
            if (edge.first == a && edge.second == b) return true;
        return false;
    };
    require(linked(1, 2) && linked(2, 3) &&
            linked(3, 4) && linked(1, 4),
            "fixture must contain 4-cycle perimeter edges");
    require(!linked(1, 3) && !linked(2, 4),
            "fixture must not contain cycle chords");
    bool found = false;
    for (const ReferenceLoopCollapseCandidate& candidate : graph.loop_candidates)
    {
        if (candidate.vertices != std::vector<std::size_t>{1, 2, 3, 4})
            continue;
        require(std::abs(candidate.representative.point.x - 0.5) < 1.0e-9,
                "4-cycle polygon centroid X incorrect");
        require(std::abs(candidate.representative.point.y - 0.5) < 1.0e-9,
                "4-cycle polygon centroid Y incorrect");
        require(candidate.representative.radius > 0.0,
                "4-cycle centroid must have valid wall clearance");
        found = true;
    }
    require(found, "Native must prevalidate an induced 4-cycle");
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
    test_signed_corner_turn_accumulation();
    test_room_reflex_threshold_15_degree_turn();
    test_cumulative_reflex_turn_on_curved_wall();
    test_smooth_concave_wall_retains_safe_navigation_candidates();
    test_local_width_limits_cluster_radius();
    test_concave_room_reference_points();
    test_state_anchored_room_reference_cluster();
    test_non_room_reference_points_are_empty();
    test_room_visibility_graph_circle_overlap_and_blocked_los();
    test_triangle_loop_candidates_are_validated_in_native();
    test_triangle_loop_new_edge_can_cross_non_overlapping_circles();
    test_triangle_loop_new_edges_still_reject_wall_crossings();
    test_four_cycle_native_centroid_and_los_candidate();
    return 0;
}
