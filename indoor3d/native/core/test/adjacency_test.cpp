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

// Proper closed shell: 10x10 Room with an open-through square hole.
// The floor and ceiling are tiled around the hole; both outer and inner
// vertical walls participate in the State-Z wall slice.
CellData ring_prism_cell()
{
    CellData cell;
    cell.index = 0;
    cell.flags = CELL_FLAG_NEEDS_STATE;
    cell.category = CellSpaceCategory::Room;
    cell.bounds = box(0,0,0,10,10,1);

    const std::array<std::array<double,4>,4> rectangles{{
        {{0,0,10,4.9}},
        {{0,5.1,10,10}},
        {{0,4.9,4.9,5.1}},
        {{5.1,4.9,10,5.1}}
    }};
    for (const auto& r : rectangles)
    {
        const Vec3 a{r[0],r[1],0}, b{r[2],r[1],0};
        const Vec3 c{r[2],r[3],0}, d{r[0],r[3],0};
        add_rect_face(cell,{0,0,-1},a,d,c,b);
        add_rect_face(cell,{0,0, 1},
            {a.x,a.y,1},{b.x,b.y,1},{c.x,c.y,1},{d.x,d.y,1});
    }

    const std::array<Vec3,4> outer{{
        {0,0,0},{10,0,0},{10,10,0},{0,10,0}
    }};
    // Clockwise inner boundary; normals point toward the empty center.
    const std::array<Vec3,4> inner{{
        {4.9,4.9,0},{4.9,5.1,0},{5.1,5.1,0},{5.1,4.9,0}
    }};
    for (const auto* ring : {&outer, &inner})
    {
        for (std::size_t i = 0; i < ring->size(); ++i)
        {
            const Vec3 a = (*ring)[i];
            const Vec3 b = (*ring)[(i + 1) % ring->size()];
            const Vec3 edge{b.x - a.x,b.y - a.y,0};
            add_rect_face(cell,{edge.y,-edge.x,0},
                a,b,{b.x,b.y,1},{a.x,a.y,1});
        }
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

// A concave arc with several small reflex turns accumulating beyond 30 degrees.
// Each local corner alone remains below the production emission threshold.
CellData gradual_reflex_arc()
{
    CellData cell;
    cell.index = 0;
    cell.category = CellSpaceCategory::Room;
    cell.flags = CELL_FLAG_NEEDS_STATE;
    cell.bounds = box(0,0,0,6,6,1);
    const std::vector<Vec3> ring{
        {0,0,0},{6,0,0},{6,6,0},{5,5.2,0},
        {4,4.8,0},{3,4.65,0},{2,4.60,0},{0,4.60,0}
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

// Room reference fixtures need wall shared edges >= 1000 mm.
// Keep the existing small State and adjacency fixtures unchanged.
CellData tall_room(CellData cell)
{
    constexpr double Z_SCALE = 80.0;
    cell.bounds.minimum.z *= Z_SCALE;
    cell.bounds.maximum.z *= Z_SCALE;
    if (cell.has_fixed_z()) cell.fixed_z *= Z_SCALE;
    for (FaceData& face : cell.faces)
    {
        for (Vec3& point : face.outer_points) point.z *= Z_SCALE;
        for (Triangle& triangle : face.triangles)
            for (Vec3& point : triangle.points) point.z *= Z_SCALE;
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

void test_floor_triangles_seed_before_without_native_pruning()
{
    CellData room = tall_room(unit_box_cell());
    room.category = CellSpaceCategory::Room;
    const CellSpaceInteriorPointResult result =
        locate_cell_space_interior_points(room, 0.001);
    require(result.state_point.has_value(), "tall Room State is missing");
    require(result.reference_status == ReferencePointStatus::Succeeded,
            "Floor Reference generation failed");

    // Exactly two triangles cover the lower face of this box.
    std::vector<Vec3> face_points, final_points;
    for (const ReferencePoint& ref : result.reference_points)
    {
        if (ref.kind == ReferencePointKind::Face)
            face_points.push_back(ref.point);
        if (ref.kind == ReferencePointKind::Final)
            final_points.push_back(ref.point);
        require(ref.kind == ReferencePointKind::Face ||
                ref.kind == ReferencePointKind::Final,
                "Triangle experiment must not create Corner/Merged refs");
    }
    require(face_points.size() == 2 && final_points.size() == 2,
            "each valid floor triangle must generate one primary graph seed");
    for (std::size_t i = 0; i < face_points.size(); ++i)
    {
        const Vec3& p = face_points[i];
        require(std::abs(p.z - 1000.0/25.4) < 1.0e-9,
                "floor centroid must move exactly +1000mm in Z");
        require(std::abs(final_points[i].x - p.x) < 1.0e-9 &&
                std::abs(final_points[i].y - p.y) < 1.0e-9 &&
                std::abs(final_points[i].z - p.z) < 1.0e-9,
                "Final must preserve unmerged primary Face candidate");
    }
    const ReferenceGraphDebug& graph = result.debug_graph;
    require(graph.nodes.size() == 3,
            "BEFORE must contain State plus all two valid floor candidates");
    require(graph.loop_candidates.empty(),
            "3D Hole verification cannot be bypassed by floor triangles");
}

void test_floor_reference_in_short_room_is_rejected()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const auto result = locate_cell_space_interior_points(room, 0.001);
    require(result.state_point.has_value(), "short Room State was lost");
    require(result.reference_points.empty(),
            "+1000mm points outside a short Solid must be rejected");
    require(result.debug_graph.nodes.size() == 1,
            "State-only BEFORE graph must still be returned for a short Room");
}

void test_inclined_floor_uses_world_z_not_surface_normal()
{
    CellData room = tall_room(unit_box_cell());
    room.category = CellSpaceCategory::Room;
    // Tilt the entire closed prism, including triangles and polygon rings.
    // Only floor/ceiling normals need to change; all four walls stay vertical.
    for (FaceData& face : room.faces)
    {
        for (Vec3& p : face.outer_points) p.z += 0.2 * p.x;
        for (Triangle& t : face.triangles)
            for (Vec3& p : t.points) p.z += 0.2 * p.x;
    }
    room.faces[0].normal = {0.2, 0, -1.0};
    room.faces[1].normal = {-0.2, 0, 1.0};
    room.bounds.maximum.z += 0.2;

    const auto references = find_reference_points(room, {0.5,0.5,40}, 0.001);
    std::size_t floor_count = 0;
    for (const ReferencePoint& ref : references)
    {
        if (ref.kind != ReferencePointKind::Face) continue;
        require(std::abs(ref.point.z -
                (1000.0/25.4 + 0.2 * ref.point.x)) < 1.0e-8,
                "sloped floor triangle must be moved along world Z");
        ++floor_count;
    }
    require(floor_count == 2,
            "inclined Floor must be triangulated without a horizontal slice");
}

void test_floor_hole_does_not_create_void_candidates()
{
    CellData room = tall_room(ring_prism_cell());
    const auto references = find_reference_points(room, {1,1,40}, 0.001);
    std::size_t count = 0;
    for (const auto& ref : references)
    {
        if (ref.kind != ReferencePointKind::Face) continue;
        require(!(ref.point.x > 4.9 && ref.point.x < 5.1 &&
                  ref.point.y > 4.9 && ref.point.y < 5.1),
                "Floor triangulation generated a point over a hole");
        ++count;
    }
    require(count > 0, "Room containing a Hole lost all floor candidates");
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
    const std::vector<ReferencePoint> points{
        {{0.3,0.3,0.5},ReferencePointKind::Final},
        {{0.7,0.3,0.5},ReferencePointKind::Final},
        {{0.5,0.7,0.5},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(
        room, {0.5,0.5,0.5}, points, 0.001);
    require(graph.nodes.size() == 4, "Room must retain graph nodes");
    require(graph.loop_candidates.empty(),
            "Native must not issue uncertified 3D Loop/Hole Collapse");
}

void test_triangle_loop_new_edge_can_cross_non_overlapping_circles()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.2,0.2,0.5},ReferencePointKind::Final},
        {{0.4,0.2,0.5},ReferencePointKind::Final},
        {{0.2,0.4,0.5},ReferencePointKind::Final},
        {{0.78,0.25,0.5},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(
        room, {0.9,0.9,0.5}, points, 0.001);
    require(graph.nodes.size() == 5 && !graph.edges.empty(),
            "original Sphere/LOS links must survive while Collapse is disabled");
    require(graph.loop_candidates.empty(),
            "unverified 3D centroid must not invent replacement edges");
}

void test_triangle_loop_new_edges_still_reject_wall_crossings()
{
    CellData room = u_prism_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.35,2.1,0.5},ReferencePointKind::Final},
        {{0.65,2.1,0.5},ReferencePointKind::Final},
        {{0.5,2.45,0.5},ReferencePointKind::Final},
        {{2.5,2.2,0.5},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(
        room, {1.5,0.5,0.5}, points, 0.001);
    require(graph.nodes.size() == 5, "U Room must retain nodes");
    require(graph.loop_candidates.empty(),
            "unverified 3D loop must never cross the Room boundary");
}

void test_four_cycle_native_centroid_and_los_candidate()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.27,0.27,0.5},ReferencePointKind::Final},
        {{0.73,0.27,0.5},ReferencePointKind::Final},
        {{0.73,0.73,0.5},ReferencePointKind::Final},
        {{0.27,0.73,0.5},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(
        room, {0.1,0.1,0.5}, points, 0.001);
    require(graph.nodes.size() == 5, "4-cycle vertices must survive");
    require(graph.loop_candidates.empty(),
            "Native cannot collapse a 3D cycle without Hole verification");
}

void test_room_loop_cannot_collapse_over_enclosed_hole()
{
    const CellData ring = ring_prism_cell();
    const std::vector<ReferencePoint> points{
        {{3,3,0.5}, ReferencePointKind::Final},
        {{7,3,0.5}, ReferencePointKind::Final},
        {{7,7,0.5}, ReferencePointKind::Final},
        {{3,7,0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug graph =
        build_room_reference_visibility_graph(ring, {1,1,0.5}, points, 0.001);
    require(graph.nodes.size() == 5, "Ring Room graph lost a vertex");
    const auto linked = [&](std::size_t a, std::size_t b) {
        return std::any_of(graph.edges.begin(), graph.edges.end(),
            [&](const ReferenceGraphEdge& edge) {
                return edge.first == a && edge.second == b;
            });
    };
    // The fixture is only one inch high. True 3D inscribed spheres
    // are limited by its floor/ceiling and need not overlap across
    // the wide ring even when the old XY disks did.
    require(graph.loop_candidates.empty(),
            "Ring Room Hole must never be collapsed without 3D certification");
    require(!linked(1,3) && !linked(2,4),
            "Ring Room diagonals may not cross the hole");
    for (const auto& candidate : graph.loop_candidates)
        require(candidate.vertices != std::vector<std::size_t>{1,2,3,4},
                "Native must not collapse a cycle enclosing a Room hole");

    // The State-containing version is subject to the SAME topology rule.
    const std::vector<ReferencePoint> other{
        {{7,3,0.5}, ReferencePointKind::Final},
        {{7,7,0.5}, ReferencePointKind::Final},
        {{3,7,0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug state_graph =
        build_room_reference_visibility_graph(ring, {3,3,0.5}, other, 0.001);
    require(state_graph.nodes.size() == 4,
            "State-containing Ring Room graph lost a vertex");
    for (const auto& candidate : state_graph.loop_candidates)
        require(candidate.vertices != std::vector<std::size_t>{0,1,2,3},
                "State cycles may not bypass the enclosed-hole protection");
}

void test_state_loop_receives_hole_free_native_certificate()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.3,0.2,0.5},ReferencePointKind::Final},
        {{0.2,0.3,0.5},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(
        room, {0.2,0.2,0.5}, points, 0.001);
    require(graph.loop_candidates.empty(),
            "State-containing cycle must not bypass missing 3D Hole validation");
}

void test_room_reference_shortcut_los_rejects_wall_crossing()
{
    CellData room = u_prism_cell();
    room.category = CellSpaceCategory::Room;
    const Vec3 left{0.5, 2.5, 0.5};
    const Vec3 right{2.5, 2.5, 0.5};
    const Vec3 left_low{0.5, 0.5, 0.5};
    const Vec3 right_low{2.5, 0.5, 0.5};
    const std::vector<std::pair<Vec3, Vec3>> segments{
        {left, right},      // Cuts the empty center of the U footprint.
        {left_low, right_low}, // Inside the bottom bridge of the U.
        {left, left_low}    // Inside the left arm.
    };
    const auto result = validate_room_reference_segments(room, segments, 0.001);
    require(result.size() == 3, "Room LOS response count mismatch");
    require(!result[0], "Room LOS must reject a shortcut across the U notch");
    require(result[1] && result[2], "Room LOS rejected valid in-Room shortcuts");

    const CellData cube = unit_box_cell();
    const auto clear = validate_room_reference_segments(
        cube, {{{0.2, 0.2, 0.5}, {0.8, 0.8, 0.5}}}, 0.001
    );
    // Category Unknown in the generic fixture: LOS service is Room-only.
    require(clear.size() == 1 && !clear[0],
            "Room LOS must reject non-Room requests");
}

void test_3d_sphere_and_vertical_los()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.5,0.5,0.2},ReferencePointKind::Final},
        {{0.5,0.5,0.8},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(
        room, {0.5,0.5,0.5}, points, 0.001);
    require(graph.nodes.size() == 3, "Sphere test lost nodes");
    require(std::abs(graph.nodes[1].radius - 0.199) < 1.0e-9 &&
            std::abs(graph.nodes[2].radius - 0.199) < 1.0e-9,
            "inscribed Sphere radius must include floor and ceiling");
    for (const ReferenceGraphEdge& edge : graph.edges)
        require(!(edge.first == 1 && edge.second == 2),
                "XY coincident but Z-separated spheres must not connect");

    const auto los = validate_room_reference_segments(
        room, {{{0.2,0.2,0.2},{0.8,0.8,0.8}},
               {{0.2,0.2,0.2},{1.5,0.8,0.8}}}, 0.001);
    require(los.size() == 2 && los[0] && !los[1],
            "3D Room LOS must allow vertical motion only inside its Solid");
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










    test_floor_triangles_seed_before_without_native_pruning();
    test_floor_reference_in_short_room_is_rejected();
    test_inclined_floor_uses_world_z_not_surface_normal();
    test_floor_hole_does_not_create_void_candidates();
    test_3d_sphere_and_vertical_los();
    test_non_room_reference_points_are_empty();

    test_room_visibility_graph_circle_overlap_and_blocked_los();
    test_room_reference_shortcut_los_rejects_wall_crossing();
    test_triangle_loop_candidates_are_validated_in_native();
    test_triangle_loop_new_edge_can_cross_non_overlapping_circles();
    test_triangle_loop_new_edges_still_reject_wall_crossings();
    test_four_cycle_native_centroid_and_los_candidate();
    test_room_loop_cannot_collapse_over_enclosed_hole();
    test_state_loop_receives_hole_free_native_certificate();
    return 0;
}
