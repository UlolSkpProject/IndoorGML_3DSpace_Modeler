#include "adjacency_checker.h"
#include "cell_space_interior_point_locator.h"
#include "floor_polygon_preparation.h"
#include "reference_graph_pipeline.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <set>
#include <stdexcept>
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

CellData reference_box_cell(double width=20.0,double height=80.0)
{
    const double w=width,h=height;
    const Vec3 a{0,0,0},b{w,0,0},c{w,w,0},d{0,w,0};
    const Vec3 A{0,0,h},B{w,0,h},C{w,w,h},D{0,w,h};
    CellData cell;
    cell.index=0;
    cell.category=CellSpaceCategory::Room;
    cell.flags=CELL_FLAG_NEEDS_STATE|CELL_FLAG_ADJACENCY_TARGET;
    cell.bounds=box(0,0,0,w,w,h);
    add_rect_face(cell,{0,0,-1},a,d,c,b);
    add_rect_face(cell,{0,0,1},A,B,C,D);
    add_rect_face(cell,{0,-1,0},a,b,B,A);
    add_rect_face(cell,{1,0,0},b,c,C,B);
    add_rect_face(cell,{0,1,0},c,d,D,C);
    add_rect_face(cell,{-1,0,0},d,a,A,D);
    return cell;
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

CellData scale_xy(CellData cell,double scale)
{
    cell.bounds.minimum.x*=scale;
    cell.bounds.minimum.y*=scale;
    cell.bounds.maximum.x*=scale;
    cell.bounds.maximum.y*=scale;
    for (FaceData& face:cell.faces)
    {
        for (Vec3& point:face.outer_points)
        {
            point.x*=scale;
            point.y*=scale;
        }
        for (Triangle& triangle:face.triangles)
            for (Vec3& point:triangle.points)
            {
                point.x*=scale;
                point.y*=scale;
            }
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

void test_convex_floor_one_area_centroid_before()
{
    CellData room=reference_box_cell();
    room.category = CellSpaceCategory::Room;
    const CellSpaceInteriorPointResult result =
        locate_cell_space_interior_points(room, 0.001);
    require(result.state_point.has_value(),
            "State must be selected from the AABB-nearest valid polygon centroid");
    require(result.reference_status == ReferencePointStatus::Succeeded,
            "Floor Reference generation failed");

    // Two mesh triangles cover ONE convex, hole-free Floor Face.
    // BEFORE must contain one area-centroid node rather than two.
    std::vector<Vec3> final_points;
    for (const ReferencePoint& ref : result.reference_points)
    {
        if (ref.kind == ReferencePointKind::Final)
            final_points.push_back(ref.point);
        require(ref.kind == ReferencePointKind::Final,
                "BEFORE must expose every accepted seed as a Final reference");
    }
    require(final_points.size() == 1,
            "convex Floor must merge mesh triangles into one reference");
    for (const Vec3& p : final_points)
    {
        require(std::abs(p.z - 1000.0/25.4) < 1.0e-9 &&
                std::abs(p.x - 10.0) < 1.0e-9 &&
                std::abs(p.y - 10.0) < 1.0e-9,
                "convex Floor area centroid must move exactly +1000mm in Z");
    }
    const ReferenceGraphDebug& graph = result.debug_graph;
    require(graph.nodes.size() == 1,
            "BEFORE must contain only the convex Floor reference");
    require(graph.loop_candidates.empty(),
            "3D Hole verification cannot be bypassed by floor triangles");
}

void test_native_reference_pipeline_bakes_state_tree_and_transition()
{
    CellData room=tall_room(unit_box_cell());
    room.category=CellSpaceCategory::Room;
    ReferenceGraphDebug before;
    const Vec3 state{0.5,0.5,1000.0/25.4};
    before.nodes.push_back({state,1.0});
    before.state_node_index=0;
    const auto pipeline=build_reference_graph_pipeline(
        room,before,0.001
    );
    require(pipeline.state_node_index<pipeline.optimized.nodes.size() &&
            pipeline.shortest_path_tree.root==pipeline.state_node_index &&
            pipeline.shortest_path_tree.distances.size()==pipeline.optimized.nodes.size(),
            "Native State-root shortest-path tree was not baked");
    const Vec3 waypoint{0.75,0.5,1000.0/25.4};
    const auto path=reference_transition_polyline(pipeline,waypoint);
    require(path.size()==2 &&
            std::abs(path.front().x-state.x)<1.0e-9 &&
            std::abs(path.back().x-waypoint.x)<1.0e-9,
            "Native Transition did not restore State-to-waypoint polyline");
}

void test_non_partitioned_state_is_a_single_node_reference_graph()
{
    CellData cell;
    const Vec3 state{1.0,2.0,3.0};
    const auto pipeline=build_state_reference_graph_pipeline(state,cell,0.001);
    for(const auto stage:{ReferenceGraphStage::Before,ReferenceGraphStage::Collapsed,
                          ReferenceGraphStage::Optimized,ReferenceGraphStage::LosGraph,
                          ReferenceGraphStage::ConnectivityRepair})
    {
        const auto& graph=reference_graph_stage(pipeline,stage);
        require(graph.nodes.size()==1 && graph.edges.empty() &&
                graph.node_roles.size()==1 &&
                graph.node_roles[0]==ReferenceNodeRole::State,
                "State-only category must retain one protected reference node");
        require(std::abs(graph.nodes[0].point.x-state.x)<1.0e-9 &&
                std::abs(graph.nodes[0].point.y-state.y)<1.0e-9 &&
                std::abs(graph.nodes[0].point.z-state.z)<1.0e-9,
                "State-only reference graph moved its State node");
    }
    require(pipeline.state_node_index==0 &&
            pipeline.shortest_path_tree.root==0 &&
            pipeline.shortest_path_tree.distances.size()==1 &&
            pipeline.shortest_path_tree.distances[0]==0.0 &&
            pipeline.shortest_path_tree.previous.size()==1 &&
            !pipeline.shortest_path_tree.previous[0],
            "State-only reference graph must bake a zero-length State tree");
    const Vec3 waypoint{4.0,5.0,6.0};
    const auto path=reference_transition_polyline(pipeline,waypoint);
    require(path.size()==2 &&
            std::abs(path.front().x-state.x)<1.0e-9 &&
            std::abs(path.back().x-waypoint.x)<1.0e-9,
            "State-only reference graph must route State directly to waypoint");
}

void test_reference_short_path_graph_uses_baked_state_tree()
{
    ReferenceGraphPipeline pipeline;
    pipeline.optimized.nodes={
        {{0,0,0},1.0},
        {{1,0,0},1.0},
        {{2,0,0},1.0},
        {{3,0,0},1.0}
    };
    // The LOS graph retains an alternate edge; the Dijkstra tree does not.
    pipeline.optimized.edges={{0,1},{0,2},{1,2}};
    pipeline.los_graph=pipeline.optimized;
    pipeline.repaired_graph=pipeline.los_graph;
    pipeline.state_node_index=0;
    pipeline.shortest_path_tree.root=0;
    pipeline.shortest_path_tree.distances={
        0.0,1.0,2.0,std::numeric_limits<double>::infinity()
    };
    pipeline.shortest_path_tree.previous={
        std::nullopt,0,1,std::nullopt
    };

    const auto graph=reference_short_path_graph(pipeline);
    require(graph.nodes.size()==4 && graph.edges.size()==2,
            "Shortest path debug graph must preserve every OPTIMIZED node "
            "and exclude non-tree edges");
    require(graph.edges[0].first==0 && graph.edges[0].second==1 &&
            graph.edges[1].first==1 && graph.edges[1].second==2,
            "Shortest path debug edges must use baked Dijkstra predecessors");
    require(pipeline.optimized.edges.size()==3 &&
            !std::isfinite(pipeline.shortest_path_tree.distances[3]),
            "Debug snapshot must not mutate the OPTIMIZED graph or connect an unreachable node");

    CellData legacy_cell;
    const auto legacy=build_state_reference_graph_pipeline({4,5,6},legacy_cell,0.001);
    const auto legacy_graph=reference_short_path_graph(legacy);
    require(legacy_graph.nodes.size()==1 && legacy_graph.edges.empty(),
            "Legacy State-only pipeline must display its single State node");
}

void test_waypoint_anchor_uses_closest_reachable_optimized_node()
{
    ReferenceGraphPipeline pipeline;
    pipeline.optimized.nodes={
        {{0.0,0.0,10.0},0.0},
        {{1.0,0.0,20.0},0.0},
        {{2.0,0.0,30.0},0.0}
    };
    pipeline.los_graph=pipeline.optimized;
    pipeline.repaired_graph=pipeline.los_graph;
    pipeline.shortest_path_tree.root=0;
    pipeline.shortest_path_tree.distances={
        0.0,1.0,std::numeric_limits<double>::infinity()
    };
    pipeline.shortest_path_tree.previous={
        std::nullopt,0,std::nullopt
    };

    const auto closest=closest_reachable_reference_point(
        pipeline,{2.0,0.0,30.0});
    require(closest.has_value() && std::abs(closest->z-20.0)<1.0e-9,
            "Waypoint anchor must ignore a closer OPTIMIZED node unreachable from State");
}

void test_native_reference_pipeline_optimizes_degree_two_and_collapses_certificate()
{
    CellData room=tall_room(unit_box_cell());
    room.category=CellSpaceCategory::Room;
    const double z=1000.0/25.4;

    ReferenceGraphDebug cluster;
    cluster.nodes={
        {{0.1,0.1,z},0.0},{{0.2,0.5,z},1.0},
        {{0.4,0.5,z},0.5},{{0.6,0.5,z},0.0}
    };
    cluster.edges={{0,1},{1,2},{2,3}};
    cluster.state_node_index=0;
    const auto after=build_reference_graph_pipeline(room,cluster,0.001);
    require(after.before.nodes.size()==4 && after.collapsed.nodes.size()==4,
            "Without AFTER, the uncontracted references must survive COLLAPSED");

    ReferenceGraphDebug chain;
    chain.nodes={
        {{0.1,0.5,z},0.0},{{0.5,0.5,z},0.0},{{0.9,0.5,z},0.0}
    };
    chain.edges={{0,1},{1,2}};
    chain.state_node_index=0;
    const auto optimized=build_reference_graph_pipeline(room,chain,0.001);
    require(optimized.before.nodes.size()==3 &&
            optimized.collapsed.nodes.size()==3 &&
            optimized.optimized.nodes.size()==2 &&
            optimized.optimized.edges.size()==1,
            "Native OPTIMIZED must remove a clear degree-2 node");
    require(optimized.shortest_path_tree.distances.size()==2 &&
            std::isfinite(optimized.shortest_path_tree.distances[1]),
            "Native optimized State tree must reach the surviving endpoint");

    ReferenceGraphDebug loop;
    loop.nodes={
        {{0.5,0.1,z},0.0},{{0.2,0.2,z},0.0},
        {{0.8,0.2,z},0.0},{{0.5,0.8,z},0.0}
    };
    loop.edges={{0,1},{1,2},{1,3},{2,3}};
    loop.state_node_index=0;
    ReferenceLoopCollapseCandidate certificate;
    certificate.vertices={1,2,3};
    certificate.representative={{0.5,0.4,z},0.0};
    certificate.visible_neighbors={0};
    loop.loop_candidates.push_back(certificate);
    const auto collapsed=build_reference_graph_pipeline(room,loop,0.001);
    require(collapsed.before.nodes.size()==4 &&
            collapsed.collapsed.nodes.size()==2 &&
            collapsed.optimized.nodes.size()==2 &&
            collapsed.optimized.edges.size()==1 &&
            collapsed.collapsed.node_roles[0]==ReferenceNodeRole::State &&
            collapsed.collapsed.node_roles[1]==ReferenceNodeRole::CollapseRepresentative &&
            collapsed.optimized.node_roles[1]==ReferenceNodeRole::CollapseRepresentative,
            "Certified Loop Collapse must retain State and protected representative");
}

void test_reference_node_roles_have_stage_scoped_protection()
{
    CellData room=tall_room(unit_box_cell());
    room.category=CellSpaceCategory::Room;
    const double z=1000.0/25.4;

    // An unused certificate cannot globally pin its vertices or LOS-visible
    // neighbors. A line has no closed cycle, so Collapse must reject it.
    ReferenceGraphDebug before;
    before.nodes={
        {{0.1,0.5,z},0.0},{{0.2,0.5,z},0.0},
        {{0.3,0.5,z},0.0},{{0.4,0.5,z},0.0},
        {{0.5,0.5,z},0.0},{{0.6,0.5,z},0.0}
    };
    before.edges={{0,1},{1,2},{2,3},{3,4},{4,5}};
    before.state_node_index=0;
    ReferenceLoopCollapseCandidate unused;
    unused.vertices={1,2,3}; // No closing 3->1 Edge.
    unused.representative={{0.3,0.5,z},0.1};
    unused.visible_neighbors={4};
    before.loop_candidates.push_back(unused);

    const auto result=build_reference_graph_pipeline(room,before,0.001);
    require(result.before.node_roles.size()==6 &&
            result.before.node_roles[0]==ReferenceNodeRole::State,
            "State must be the sole hard-protected BEFORE reference");
    for(std::size_t i=1;i<6;++i)
        require(result.before.node_roles[i]==ReferenceNodeRole::Reference,
                "Candidate vertices and visible neighbors are not node roles");
    require(result.collapsed.nodes.size()==6,
            "Unused certificate must leave COLLAPSED nodes unchanged");
    require(result.optimized.nodes.size()==2 &&
            result.optimized.node_roles[0]==ReferenceNodeRole::State &&
            result.optimized.node_roles[1]==ReferenceNodeRole::Reference,
            "OPTIMIZED must remove unprotected degree-2 candidate neighbors");

    require(reference_node_protected_from_optimization(ReferenceNodeRole::State) &&
            reference_node_protected_from_optimization(ReferenceNodeRole::CollapseRepresentative) &&
            !reference_node_protected_from_optimization(ReferenceNodeRole::Reference) &&
            !reference_node_protected_from_optimization(ReferenceNodeRole::RecoveredReference),
            "Protection must depend on node role and the optimization Stage");
}

void test_successful_loop_visible_neighbor_is_not_optimization_protected()
{
    CellData room=tall_room(unit_box_cell());
    room.category=CellSpaceCategory::Room;
    const double z=1000.0/25.4;

    ReferenceGraphDebug before;
    before.nodes={
        {{0.10,0.45,z},0.0}, // State
        {{0.25,0.45,z},0.0}, // LOS-visible degree-2 neighbor
        {{0.40,0.30,z},0.0},
        {{0.50,0.70,z},0.0},
        {{0.60,0.30,z},0.0}
    };
    before.edges={{0,1},{1,2},{2,3},{3,4},{2,4}};
    before.state_node_index=0;
    ReferenceLoopCollapseCandidate certificate;
    certificate.vertices={2,3,4};
    certificate.representative={{0.50,0.45,z},0.1};
    certificate.visible_neighbors={1};
    before.loop_candidates.push_back(certificate);

    const auto result=build_reference_graph_pipeline(room,before,0.001);
    require(result.collapsed.nodes.size()==3 &&
            result.collapsed.node_roles.size()==3 &&
            result.collapsed.node_roles[0]==ReferenceNodeRole::State &&
            result.collapsed.node_roles[1]==ReferenceNodeRole::Reference &&
            result.collapsed.node_roles[2]==ReferenceNodeRole::CollapseRepresentative,
            "Successful Collapse must preserve unrelated visible neighbors as ordinary references");
    require(result.optimized.nodes.size()==2 &&
            result.optimized.node_roles[0]==ReferenceNodeRole::State &&
            result.optimized.node_roles[1]==ReferenceNodeRole::CollapseRepresentative,
            "OPTIMIZED may remove a visible neighbor while preserving the Collapse representative");
    require(result.optimized.edges.size()==1 &&
            result.los_graph.edges.size()==1 &&
            result.unreachable_node_count==0,
            "Releasing a certificate's neighbor must keep the valid State-to-representative LOS route");
}

void test_collapsed_linearizes_sliver_polygon_components()
{
    CellData room=tall_room(unit_box_cell());
    room.category=CellSpaceCategory::Room;
    const double z=1000.0/25.4;

    // Three overlapping degenerate triangles form one five-node cyclic block.
    // COLLAPSED must retain every node and external edge, but replace all
    // internal chords with the unambiguous projected chain.
    ReferenceGraphDebug sliver;
    sliver.nodes={
        {{0.05,0.5,z},0.0},{{0.15,0.5,z},0.0},
        {{0.30,0.5,z},0.0},{{0.45,0.5,z},0.0},
        {{0.60,0.5,z},0.0},{{0.75,0.5,z},0.0},
        {{0.95,0.5,z},0.0}
    };
    sliver.edges={
        {0,1},
        {1,2},{1,3},{2,3},
        {2,4},{3,4},{3,5},{4,5},
        {5,6}
    };
    sliver.state_node_index=0;
    const auto linearized=build_reference_graph_pipeline(room,sliver,0.001);
    require(linearized.collapsed.nodes.size()==7 &&
            linearized.collapsed.edges.size()==6,
            "COLLAPSED must turn an overlapping sliver polygon into one path");
    for(std::size_t i=0;i<6;++i)
        require(linearized.collapsed.edges[i].first==i &&
                linearized.collapsed.edges[i].second==i+1,
                "COLLAPSED sliver path must follow projected node order");
    require(linearized.optimized.nodes.size()==2 &&
            linearized.optimized.edges.size()==1,
            "OPTIMIZED must simplify the degree-2 nodes exposed by sliver linearization");

    // A thin two-rail polygon has ambiguous projection stations and must not be
    // flattened into an arbitrary zig-zag chain.
    ReferenceGraphDebug ambiguous;
    ambiguous.nodes={
        {{0.1,0.5,z},0.0},{{0.2,0.495,z},0.0},
        {{0.8,0.495,z},0.0},{{0.8,0.505,z},0.0},
        {{0.2,0.505,z},0.0}
    };
    ambiguous.edges={{0,1},{1,2},{2,3},{3,4},{4,1}};
    ambiguous.state_node_index=0;
    const auto preserved=build_reference_graph_pipeline(room,ambiguous,0.001);
    require(preserved.collapsed.nodes.size()==5 &&
            preserved.collapsed.edges.size()==5,
            "COLLAPSED must preserve a sliver polygon without a unique longitudinal order");
}

void test_optimized_degree_two_angle_threshold_and_priority_queue()
{
    CellData room=tall_room(unit_box_cell());
    room.category=CellSpaceCategory::Room;
    const double z=1000.0/25.4;

    ReferenceGraphDebug acute;
    acute.nodes={
        {{0.1,0.1,z},0.0},{{0.5,0.7,z},0.0},{{0.9,0.1,z},0.0}
    };
    acute.edges={{0,1},{1,2}};
    acute.state_node_index=0;
    const auto acute_result=build_reference_graph_pipeline(room,acute,0.001);
    require(acute_result.optimized.nodes.size()==3 &&
            acute_result.optimized.edges.size()==2,
            "OPTIMIZED must preserve a degree-2 turn below 150 degrees");

    ReferenceGraphDebug right_angle;
    right_angle.nodes={
        {{0.1,0.1,z},0.0},{{0.5,0.5,z},0.0},{{0.9,0.1,z},0.0}
    };
    right_angle.edges={{0,1},{1,2}};
    right_angle.state_node_index=0;
    const auto right_angle_result=build_reference_graph_pipeline(room,right_angle,0.001);
    require(right_angle_result.optimized.nodes.size()==3 &&
            right_angle_result.optimized.edges.size()==2,
            "OPTIMIZED must preserve a clear degree-2 turn at 90 degrees");

    ReferenceGraphDebug obtuse;
    obtuse.nodes={
        {{0.2,0.5,z},0.0},{{0.4,0.5,z},0.0},
        {{0.4+0.2*std::cos(20.0*3.14159265358979323846/180.0),
          0.5+0.2*std::sin(20.0*3.14159265358979323846/180.0),z},0.0}
    };
    obtuse.edges={{0,1},{1,2}};
    obtuse.state_node_index=0;
    const auto obtuse_result=build_reference_graph_pipeline(room,obtuse,0.001);
    require(obtuse_result.optimized.nodes.size()==2 &&
            obtuse_result.optimized.edges.size()==1,
            "OPTIMIZED must remove a clear degree-2 turn above 150 degrees");

    // Node 2 is much straighter than Node 1 even though its stable id is higher.
    // Both initially exceed 150 degrees. Removing Node 2 first changes Node 1
    // to a sub-150-degree turn, so its refreshed heap entry must preserve it.
    // Index-order contraction would remove both.
    ReferenceGraphDebug ordered;
    ordered.nodes={
        {{0.1,0.1,z},0.0},{{0.2,0.1,z},0.0},
        {{0.287461,0.148481,z},0.0},{{0.701980,0.428077,z},0.0}
    };
    ordered.edges={{0,1},{1,2},{2,3}};
    ordered.state_node_index=0;
    const auto ordered_result=build_reference_graph_pipeline(room,ordered,0.001);
    require(ordered_result.optimized.nodes.size()==3 &&
            ordered_result.optimized.edges.size()==2,
            "OPTIMIZED must contract the straightest degree-2 candidate first");
    require(std::abs(ordered_result.optimized.nodes[1].point.x-0.2)<1.0e-9 &&
            std::abs(ordered_result.optimized.nodes[1].point.y-0.1)<1.0e-9,
            "OPTIMIZED must refresh and retain the neighbor that falls below threshold");
}

void test_full_los_connects_visible_components_to_state()
{
    for(const auto category:{CellSpaceCategory::Room,CellSpaceCategory::Stair})
    {
        CellData cell=tall_room(unit_box_cell());
        cell.category=category;
        const double z=1000.0/25.4;
        ReferenceGraphDebug before;
        before.nodes={
            {{0.1,0.2,z},0.0},{{0.3,0.2,z},0.0},
            {{0.7,0.8,z},0.0},{{0.9,0.8,z},0.0}
        };
        before.edges={{0,1},{2,3}};
        before.state_node_index=0;

        const auto pipeline=build_reference_graph_pipeline(cell,before,0.001);
        require(pipeline.optimized.nodes.size()==4 &&
                pipeline.optimized.edges.size()==2 &&
                pipeline.los_graph.edges.size()==6 &&
                pipeline.repaired_graph.nodes.size()==4 &&
                pipeline.recovered_node_count==0 &&
                pipeline.unreachable_node_count==0,
                "Full LOS must connect visible components without inserting nodes");
        require(std::all_of(
                    pipeline.shortest_path_tree.distances.begin(),
                    pipeline.shortest_path_tree.distances.end(),
                    [](double value){return std::isfinite(value);}),
                "Every bridged OPTIMIZED node must be reachable from State");
    }
}

void test_full_los_graph_ignores_optimized_edges_and_uses_all_visible_pairs()
{
    CellData room=tall_room(unit_box_cell());
    room.category=CellSpaceCategory::Room;
    const double z=1000.0/25.4;
    ReferenceGraphDebug before;
    before.nodes={
        {{0.1,0.2,z},0.0},{{0.3,0.2,z},0.0},
        {{0.7,0.8,z},0.0},{{0.9,0.8,z},0.0}
    };
    before.edges={{0,1},{2,3}};
    before.state_node_index=0;

    const auto result=build_reference_graph_pipeline(room,before,0.001);
    require(result.optimized.nodes.size()==4 &&
            result.optimized.edges.size()==2 &&
            result.los_graph.nodes.size()==4 &&
            result.los_graph.edges.size()==6,
            "Full LOS must test all node pairs, independent of OPTIMIZED edges or radii");
    require(result.shortest_path_tree.root==result.state_node_index &&
            result.unreachable_node_count==0,
            "Full LOS must preserve the existing State and find every reachable node");
    for(std::size_t i=1;i<4;++i)
    {
        require(result.shortest_path_tree.previous[i] &&
                *result.shortest_path_tree.previous[i]==result.state_node_index,
                "Full LOS Dijkstra must choose direct State edges when they are shortest");
    }
    const auto tree=reference_short_path_graph(result);
    require(tree.nodes.size()==4 && tree.edges.size()==3 &&
            result.los_graph.edges.size()==6,
            "The short-path view must show the tree, without removing full LOS choices");
}

void test_connectivity_repair_restores_two_hole_detour_nodes()
{
    const CellData cell=ring_prism_cell();
    const double tolerance=0.001;
    const FaceSolid solid(cell,tolerance);
    require(solid.valid(),"Repair fixture needs a valid ring Solid");
    ReferenceGraphStageSnapshot los;
    los.nodes={{{2,5,0.5},0.0},{{8,5,0.5},0.0}};
    los.original_indices={0,1};
    los.node_roles={ReferenceNodeRole::State,ReferenceNodeRole::Reference};

    ReferenceGraphStageSnapshot before=los;
    before.nodes.push_back({{2,5.15,0.5},0.0});
    before.nodes.push_back({{8,5.15,0.5},0.0});
    before.original_indices={0,1,2,3};
    before.node_roles={ReferenceNodeRole::State,ReferenceNodeRole::Reference,
                       ReferenceNodeRole::Reference,ReferenceNodeRole::Reference};

    const auto recovered=repair_reference_connectivity(
        los,before,before,0,solid,tolerance);
    require(recovered.added_nodes==2 &&
            recovered.graph.nodes.size()==4,
            "Disconnected ring components must restore both valid detour references");
    require(recovered.graph.edges.size()==3,
            "All recovered edges must be valid LOS segments around the hole");
    require(recovered.graph.original_indices.size()==4 &&
            recovered.graph.node_roles.size()==4 &&
            recovered.graph.node_roles[0]==ReferenceNodeRole::State &&
            recovered.graph.node_roles[1]==ReferenceNodeRole::Reference &&
            recovered.graph.node_roles[2]==ReferenceNodeRole::RecoveredReference &&
            recovered.graph.node_roles[3]==ReferenceNodeRole::RecoveredReference &&
            recovered.graph.original_indices[2]==std::optional<std::size_t>(2) &&
            recovered.graph.original_indices[3]==std::optional<std::size_t>(3),
            "Repair must retain valid candidate provenance and graph metadata");
}

void test_full_los_graph_rejects_inherited_edge_through_hole()
{
    const CellData room=ring_prism_cell();
    ReferenceGraphDebug before;
    before.nodes={{{2,5,0.5},0.0},{{8,5,0.5},0.0}};
    // Deliberately invalid inherited OPTIMIZED edge: a geometry-only LOS
    // graph must never copy it across a physical cavity.
    before.edges={{0,1}};
    before.state_node_index=0;

    const auto result=build_reference_graph_pipeline(room,before,0.001);
    require(result.optimized.edges.size()==1 &&
            result.los_graph.edges.empty() &&
            result.unreachable_node_count==1 &&
            !std::isfinite(result.shortest_path_tree.distances[1]),
            "A stale OPTIMIZED edge across a hole must not contaminate LOS routing");
    require(reference_short_path_graph(result).edges.empty(),
            "Disconnected nodes must remain isolated in the final State tree");
}

void test_disconnected_los_does_not_bridge_through_hole()
{
    const CellData room=ring_prism_cell();
    ReferenceGraphDebug before;
    before.nodes={{{2,5,0.5},0.0},{{8,5,0.5},0.0}};
    before.state_node_index=0;

    const auto pipeline=build_reference_graph_pipeline(room,before,0.001);
    require(pipeline.optimized.edges.empty() &&
            pipeline.repaired_graph.edges.empty() &&
            pipeline.recovered_node_count==0 &&
            pipeline.unreachable_node_count==1,
            "Final routing graph must not connect nodes through a hole");
    require(!std::isfinite(pipeline.shortest_path_tree.distances[1]),
            "A node behind a hole must remain unreachable without a valid bridge");
}

void test_convex_floor_asymmetric_mesh_has_area_centroid()
{
    CellData room = tall_room(unit_box_cell());
    // A skewed, four-triangle fan still covers the entire unit square.
    // Averaging triangle centroids equally would shift the result.
    const Vec3 a{0,0,0}, b{1,0,0}, c{1,1,0}, d{0,1,0};
    const Vec3 inside{0.8,0.3,0};
    room.faces[0].triangles = {
        triangle(a,b,inside), triangle(b,c,inside),
        triangle(c,d,inside), triangle(d,a,inside)
    };
    room.faces[0].outer_points = {a,b,c,d};
    const auto references = find_reference_points(room, 0.001);

    std::vector<Vec3> candidates;
    for (const auto& ref : references)
        if (ref.kind == ReferencePointKind::Face)
            candidates.push_back(ref.point);
    require(candidates.size() == 1,
            "convex Face must be one region regardless of triangulation");
    require(std::abs(candidates[0].x-0.5) < 1.0e-9 &&
            std::abs(candidates[0].y-0.5) < 1.0e-9 &&
            std::abs(candidates[0].z-1000.0/25.4) < 1.0e-9,
            "merged centroid must be area-weighted, not vertex-averaged");
}

void test_coplanar_adjacent_floor_faces_merge()
{
    CellData room = tall_room(unit_box_cell());
    const Vec3 a{0,0,0}, b{0.5,0,0}, c{0.5,1,0}, d{0,1,0};
    const Vec3 e{1,0,0}, f{1,1,0};
    FaceData left;
    left.normal = {0,0,-1};
    left.outer_points = {a,b,c,d};
    left.triangles = {triangle(a,c,b), triangle(a,d,c)};
    FaceData right;
    right.normal = {0,0,-1};
    right.outer_points = {b,e,f,c};
    right.triangles = {triangle(b,f,e), triangle(b,c,f)};
    room.faces[0] = left;
    room.faces.insert(room.faces.begin()+1, right);

    const auto references = find_reference_points(room, 0.001);
    std::size_t count = 0;
    for (const auto& ref : references)
        if (ref.kind == ReferencePointKind::Face)
        {
            require(std::abs(ref.point.x-0.5) < 1.0e-9 &&
                    std::abs(ref.point.y-0.5) < 1.0e-9,
                    "same-plane split Faces must share their area centroid");
            ++count;
        }
    require(count == 1,
            "multiple adjacent coplanar Floor Faces must form one convex region");
}

void test_concave_floor_partitions_without_filling_its_notch()
{
    CellData room = tall_room(u_prism_cell());
    // Combine the bottom and two arms into ONE concave SketchUp Face;
    // its mesh remains six valid triangles covering the U floor.
    FaceData combined = room.faces[0];
    for (std::size_t id = 1; id < 3; ++id)
        combined.triangles.insert(combined.triangles.end(),
            room.faces[id].triangles.begin(), room.faces[id].triangles.end());
    room.faces.erase(room.faces.begin(),room.faces.begin()+3);
    room.faces.insert(room.faces.begin(), combined);

    const auto references = find_reference_points(room, 0.001);
    std::size_t count = 0;
    for (const auto& ref : references)
    {
        if (ref.kind != ReferencePointKind::Face) continue;
        const Vec3& p = ref.point;
        const bool in_bottom = p.y > 0 && p.y < 1 && p.x > 0 && p.x < 3;
        const bool in_left = p.x > 0 && p.x < 1 && p.y > 0 && p.y < 3;
        const bool in_right = p.x > 2 && p.x < 3 && p.y > 0 && p.y < 3;
        require(in_bottom || in_left || in_right,
                "concave Floor partition centroid escaped the actual Solid");
        ++count;
    }
    require(count >= 2 && count < 6,
            "concave Floor must be partitioned into fewer convex regions");
}

// The same -30-degree signed-turn policy used by the former wall
// corner detector is now used to decide whether a Floor region needs
// partitioning. A shallow reflex does NOT force an extra Reference Point.
void test_floor_single_reflex_below_30_degrees_stays_one_region()
{
    const std::array<double,2> shallow_depths{{0.25, 0.5}};
    for (double depth : shallow_depths)
    {
        CellData room = tall_room(shallow_reflex_prism_cell(depth));
        const auto references = find_reference_points(room, 0.001);
        std::size_t face_count=0;
        for (const ReferencePoint& point : references)
            if (point.kind == ReferencePointKind::Face) ++face_count;
        require(face_count == 1,
                "14- or 28-degree single reflex must keep one Floor region");
    }
}

void test_floor_single_reflex_over_30_degrees_forces_partition()
{
    CellData room = tall_room(shallow_reflex_prism_cell(0.7));
    const auto references = find_reference_points(room, 0.001);
    std::size_t face_count=0;
    for (const ReferencePoint& point : references)
        if (point.kind == ReferencePointKind::Face) ++face_count;
    require(face_count >= 2,
            "38-degree single reflex must prevent whole-Floor merge");
}

void test_floor_many_small_reflex_turns_accumulate()
{
    CellData room = tall_room(gradual_reflex_arc());
    const auto references = find_reference_points(room, 0.001);
    std::size_t face_count=0;
    for (const ReferencePoint& point : references)
        if (point.kind == ReferencePointKind::Face) ++face_count;
    // Individual curved-wall turns are 16.86, 13.27, 5.67 and
    // 2.86 degrees. Their negative run exceeds the cumulative 30.
    require(face_count >= 2,
            "small reflex corners accumulating beyond 30deg must partition");
}

void test_floor_cumulative_turn_respects_convex_cancellation()
{
    // The shared accumulator is independent of a particular Face fixture.
    // Positive bends reduce the still-open reflex run, as for wall corners.
    RoomSignedTurnAccumulator accumulation(30.0);
    require(!accumulation.advance(-16.0), "first 16deg is too shallow");
    require(!accumulation.advance(+8.0), "convex turn must offset reflex");
    require(!accumulation.advance(-21.0),
            "net -29deg must not force a Floor split");
    require(accumulation.advance(-1.0),
            "net -30deg must force a Floor split");
}

void test_floor_reference_in_short_room_uses_legacy_fallback()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const auto modern=locate_reference_before(room,0.001);
    require(!modern.state_point.has_value(),
            "modern policy must reject a short or malformed Floor candidate");

    const auto result=locate_cell_space_interior_points(room,0.001);
    require(result.state_point.has_value() && result.used_legacy_fallback,
            "short Room must recover per-cell through legacy State fallback");
    require(result.reference_points.empty() && result.debug_graph.nodes.empty(),
            "legacy fallback must not fabricate modern BEFORE nodes");
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

    const auto references = find_reference_points(room, 0.001);
    std::size_t floor_count = 0;
    for (const ReferencePoint& ref : references)
    {
        if (ref.kind != ReferencePointKind::Face) continue;
        require(std::abs(ref.point.z -
                (1000.0/25.4 + 0.2 * ref.point.x)) < 1.0e-8,
                "sloped floor triangle must be moved along world Z");
        ++floor_count;
    }
    require(floor_count == 1,
            "coplanar sloped Floor triangles must merge into one area centroid");
}

void test_floor_hole_does_not_create_void_candidates()
{
    CellData room = tall_room(ring_prism_cell());
    const auto references = find_reference_points(room, 0.001);
    std::size_t count = 0;
    for (const auto& ref : references)
    {
        if (ref.kind != ReferencePointKind::Face) continue;
        require(!(ref.point.x > 4.9 && ref.point.x < 5.1 &&
                  ref.point.y > 4.9 && ref.point.y < 5.1),
                "Floor triangulation generated a point over a hole");
        ++count;
    }
    require(count == 4,
            "Floor with a Hole must remain split into four safe convex strips");
}

void test_single_floor_face_with_hole_keeps_multiple_regions()
{
    CellData room = tall_room(ring_prism_cell());
    // Represent the whole ring Floor as ONE SketchUp Face with an
    // inner loop, using its eight pre-existing constrained triangles.
    FaceData ring_face = room.faces[0];
    for (std::size_t id=1; id<4; ++id)
        ring_face.triangles.insert(ring_face.triangles.end(),
            room.faces[id].triangles.begin(), room.faces[id].triangles.end());
    room.faces.erase(room.faces.begin(), room.faces.begin()+4);
    room.faces.insert(room.faces.begin(), ring_face);

    const auto references = find_reference_points(room, 0.001);
    std::size_t count = 0;
    for (const ReferencePoint& ref : references)
    {
        if (ref.kind != ReferencePointKind::Face) continue;
        const Vec3& p = ref.point;
        require(p.x > 0 && p.x < 10 && p.y > 0 && p.y < 10,
                "single-Face Hole region centroid escaped outer boundary");
        require(!(p.x > 4.9 && p.x < 5.1 &&
                  p.y > 4.9 && p.y < 5.1),
                "single-Face Hole must not be filled by a convex merge");
        ++count;
    }
    require(count >= 4 && count < 8,
            "Hole Face must partition into safe regions, not keep every triangle");
}

void test_room_visibility_graph_circle_overlap_and_blocked_los()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.2, 0.5, 0.5}, ReferencePointKind::Final},
        {{0.8, 0.5, 0.5}, ReferencePointKind::Final},
        {{0.3, 0.3, 0.5}, ReferencePointKind::Corner}
    };
    const ReferenceGraphDebug graph =
        build_room_reference_visibility_graph(room, points, 0.001);
    require(graph.nodes.size() == 2,
            "graph must contain Final refs only, not diagnostic candidates");
    require(graph.edges.empty(),
            "non-overlapping Final spheres must not connect");
    require(std::abs(graph.nodes[0].radius - 0.199) < 1.0e-9,
            "Final disk radius must not cross the nearest XY wall");
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
        build_room_reference_visibility_graph(u, blocked_points, 0.001);
    require(blocked.nodes.size() == 2, "U room must preserve both Final nodes");
    for (const ReferenceGraphEdge& edge : blocked.edges)
        require(!(edge.first == 0 && edge.second == 1),
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
    const auto graph = build_room_reference_visibility_graph(room, points, 0.001);
    require(graph.nodes.size() == 3, "Room must retain graph nodes");
    require(!graph.loop_candidates.empty(),
            "hole-free planar Room loop must receive a Native membrane certificate");
    for (const auto& candidate : graph.loop_candidates)
        require(candidate.representative.radius > 0.0,
                "certified membrane representative needs positive 3D clearance");
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
    const auto graph = build_room_reference_visibility_graph(room, points, 0.001);
    require(graph.nodes.size() == 4 && !graph.edges.empty(),
            "original Sphere/LOS links must survive while Collapse is disabled");
    // Safe planar cycles may now have a certified representative.
    // An invented external Edge still needs explicit Native LOS.
    for (const auto& candidate : graph.loop_candidates)
        require(candidate.representative.radius > 0.0,
                "virtual-mesh center must have positive 3D clearance");
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
    const auto graph = build_room_reference_visibility_graph(room, points, 0.001);
    require(graph.nodes.size() == 4, "U Room must retain nodes");
    for (const auto& candidate : graph.loop_candidates)
        if (candidate.vertices == std::vector<std::size_t>{0,1,2})
            require(std::find(candidate.visible_neighbors.begin(),
                              candidate.visible_neighbors.end(), 3) ==
                        candidate.visible_neighbors.end(),
                    "a certified Loop must not invent LOS across the U void");
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
    const auto graph = build_room_reference_visibility_graph(room, points, 0.001);
    require(graph.nodes.size() == 4, "4-cycle vertices must survive");
    bool found_four_cycle=false;
    for (const auto& candidate : graph.loop_candidates)
        if (candidate.vertices == std::vector<std::size_t>{0,1,2,3})
            found_four_cycle=true;
    require(found_four_cycle,
            "planar, hole-free four-cycle must certify its virtual mesh");
}

void test_tilted_planar_loop_virtual_membrane_is_certified()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.27,0.27,0.477},ReferencePointKind::Final},
        {{0.73,0.27,0.523},ReferencePointKind::Final},
        {{0.73,0.73,0.523},ReferencePointKind::Final},
        {{0.27,0.73,0.477},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(room,points,0.001);
    bool found=false;
    for (const auto& cert : graph.loop_candidates)
        if (cert.vertices == std::vector<std::size_t>{0,1,2,3})
        {
            require(cert.representative.radius > 0.0,
                    "tilted membrane needs an inscribed 3D sphere");
            found=true;
        }
    require(found,"tilted but planar four-cycle must be eligible");
}

void test_warped_four_loop_has_no_unique_membrane()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.27,0.27,0.45},ReferencePointKind::Final},
        {{0.73,0.27,0.55},ReferencePointKind::Final},
        {{0.73,0.73,0.45},ReferencePointKind::Final},
        {{0.27,0.73,0.55},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(room,points,0.001);
    for (const auto& cert : graph.loop_candidates)
        require(cert.vertices != std::vector<std::size_t>{0,1,2,3},
                "noncoplanar four-cycle cannot claim one Hole-free membrane");
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
        build_room_reference_visibility_graph(ring, points, 0.001);
    require(graph.nodes.size() == 4, "Ring Room graph lost a vertex");
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
    require(!linked(0,2) && !linked(1,3),
            "Ring Room diagonals may not cross the hole");
    for (const auto& candidate : graph.loop_candidates)
        require(candidate.vertices != std::vector<std::size_t>{0,1,2,3},
                "Native must not collapse a cycle enclosing a Room hole");

    // Any subset is subject to the SAME topology rule.
    const std::vector<ReferencePoint> other{
        {{7,3,0.5}, ReferencePointKind::Final},
        {{7,7,0.5}, ReferencePointKind::Final},
        {{3,7,0.5}, ReferencePointKind::Final}
    };
    const ReferenceGraphDebug subset_graph =
        build_room_reference_visibility_graph(ring, other, 0.001);
    require(subset_graph.nodes.size() == 3,
            "Ring Room subset graph lost a vertex");
    for (const auto& candidate : subset_graph.loop_candidates)
        require(candidate.vertices != std::vector<std::size_t>{0,1,2,3},
                "reference cycles may not bypass the enclosed-hole protection");
}

void test_reference_loop_receives_hole_free_native_certificate()
{
    CellData room = unit_box_cell();
    room.category = CellSpaceCategory::Room;
    const std::vector<ReferencePoint> points{
        {{0.2,0.2,0.5},ReferencePointKind::Final},
        {{0.3,0.2,0.5},ReferencePointKind::Final},
        {{0.2,0.3,0.5},ReferencePointKind::Final}
    };
    const auto graph = build_room_reference_visibility_graph(room, points, 0.001);
    bool certified=false;
    for (const auto& candidate : graph.loop_candidates)
        if (candidate.vertices == std::vector<std::size_t>{0,1,2})
        {
            require(std::abs(candidate.representative.point.x - 0.7/3.0) < 1.0e-9 &&
                    std::abs(candidate.representative.point.y - 0.7/3.0) < 1.0e-9,
                    "reference Cycle must use its certified centroid");
            certified=true;
        }
    require(certified,
            "hole-free reference Cycle requires a Native membrane certificate");
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
    const auto graph = build_room_reference_visibility_graph(room, points, 0.001);
    require(graph.nodes.size() == 2, "Sphere test lost nodes");
    require(std::abs(graph.nodes[0].radius - 0.199) < 1.0e-9 &&
            std::abs(graph.nodes[1].radius - 0.199) < 1.0e-9,
            "inscribed Sphere radius must include floor and ceiling");
    for (const ReferenceGraphEdge& edge : graph.edges)
        require(!(edge.first == 0 && edge.second == 1),
                "XY coincident but Z-separated spheres must not connect");

    const auto los = validate_room_reference_segments(
        room, {{{0.2,0.2,0.2},{0.8,0.8,0.8}},
               {{0.2,0.2,0.2},{1.5,0.8,0.8}}}, 0.001);
    require(los.size() == 2 && los[0] && !los[1],
            "3D Room LOS must allow vertical motion only inside its Solid");
}

// L-shaped prism with matched, constrained floor-mesh edges. The six
// triangles share exact vertices, including the internal edges at x=1
// and y=1. Its -90-degree reflex turn forces >=2 final Floor polygons.
CellData l_partition_prism()
{
    const std::array<Vec3,8> ring{{
        {0,0,0},{1,0,0},{3,0,0},{3,1,0},
        {1,1,0},{1,3,0},{0,3,0},{0,1,0}
    }};
    const std::array<std::array<Vec3,3>,6> mesh{{
        {{{0,0,0},{1,0,0},{1,1,0}}},
        {{{0,0,0},{1,1,0},{0,1,0}}},
        {{{1,0,0},{3,0,0},{3,1,0}}},
        {{{1,0,0},{3,1,0},{1,1,0}}},
        {{{0,1,0},{1,1,0},{1,3,0}}},
        {{{0,1,0},{1,3,0},{0,3,0}}}
    }};
    CellData cell;
    cell.index=0;
    cell.flags=CELL_FLAG_NEEDS_STATE;
    cell.category=CellSpaceCategory::Stair;
    cell.bounds=box(0,0,0,3,3,1);
    for (const auto& tri : mesh)
    {
        const Vec3 at{tri[0].x,tri[0].y,1},
                   bt{tri[1].x,tri[1].y,1},
                   ct{tri[2].x,tri[2].y,1};
        cell.faces.push_back(face({0,0,-1},
            {triangle(tri[0],tri[2],tri[1])}));
        cell.faces.push_back(face({0,0,1},
            {triangle(at,bt,ct)}));
    }
    for (std::size_t i=0;i<ring.size();++i)
    {
        const Vec3 a=ring[i],b=ring[(i+1)%ring.size()];
        const Vec3 edge{b.x-a.x,b.y-a.y,0};
        add_rect_face(cell,{edge.y,-edge.x,0},
            a,b,{b.x,b.y,1},{a.x,a.y,1});
    }
    return cell;
}

// Room AND Stair must use the SAME two seed sources after the SAME
// final Floor partition: polygon surface centroid + genuine shared-edge
// midpoint. The categories differ only in downstream graph stages.
void test_room_and_stair_both_seed_centroids_and_shared_edges()
{
    CellData cell=tall_room(scale_xy(l_partition_prism(),20.0));
    cell.category=CellSpaceCategory::Room;
    const auto room=locate_cell_space_interior_points(cell,0.001);
    cell.category=CellSpaceCategory::Stair;
    const auto stair=locate_cell_space_interior_points(cell,0.001);

    require(room.state_point.has_value() && stair.state_point.has_value(),
            "Room/Stair must select State before graph reductions");
    require(room.reference_status==ReferencePointStatus::Succeeded &&
            stair.reference_status==ReferencePointStatus::Succeeded,
            "Room and Stair must both generate BEFORE candidates");

    const auto collect=[](const CellSpaceInteriorPointResult& result,
                          ReferencePointKind kind) {
        std::vector<Vec3> result_points;
        for (const ReferencePoint& p : result.reference_points)
            if (p.kind==kind) result_points.push_back(p.point);
        return result_points;
    };
    const auto room_final=collect(room,ReferencePointKind::Final);
    const auto stair_final=collect(stair,ReferencePointKind::Final);
    require(room_final.size()>=2,
            "concave L Floor should retain its State and shared-edge midpoint");
    require(room_final.size()==stair_final.size(),
            "Room and Stair final graph nodes must have identical seed counts");

    for (std::size_t i=0;i<room_final.size();++i)
    {
        const Vec3& a=room_final[i];
        const Vec3& b=stair_final[i];
        require(std::abs(a.x-b.x)<1.0e-9 &&
                std::abs(a.y-b.y)<1.0e-9 &&
                std::abs(a.z-b.z)<1.0e-9,
                "Room and Stair must return precisely the same seed positions");
        require(std::abs(a.z-1000.0/25.4)<1.0e-9,
                "both seed kinds must retain the +1000mm world-Z lift");
    }
    require(room.debug_graph.nodes.size()==room_final.size() &&
            stair.debug_graph.nodes.size()==stair_final.size(),
            "both BEFORE graphs must contain all accepted Final seeds only");
    require(stair.debug_graph.loop_candidates.empty(),
            "Stair is BEFORE-only; do not turn on Collapse certificates");
}

void test_single_convex_floor_has_only_one_centroid_for_both()
{
    for (CellSpaceCategory category :
         {CellSpaceCategory::Room,CellSpaceCategory::Stair})
    {
        CellData cell=reference_box_cell();
        cell.category=category;
        const auto result=locate_cell_space_interior_points(cell,0.001);
        require(result.state_point.has_value(),
                "convex Room/Stair must use their polygon centroid as State");
        require(result.reference_status==ReferencePointStatus::Succeeded,
                "both Room and Stair must attempt Floor seeds");
        std::size_t final_count=0;
        for (const ReferencePoint& candidate : result.reference_points)
        {
            if (candidate.kind==ReferencePointKind::Final)
            {
                ++final_count;
                require(std::abs(candidate.point.x-10.0)<1.0e-9 &&
                        std::abs(candidate.point.y-10.0)<1.0e-9 &&
                        std::abs(candidate.point.z-1000.0/25.4)<1.0e-9,
                        "single convex Floor reference must be its area centroid");
            }
        }
        require(final_count==1,
                "internal triangulation edges must NOT generate extra seeds");
        require(result.debug_graph.nodes.size()==1,
                "Room/Stair single Floor BEFORE is one centroid only");
    }
}

void test_other_reference_categories_use_legacy_only_after_modern_failure()
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
        require(result.state_point.has_value() && result.used_legacy_fallback,
                "each short category must recover after modern failure");
        require(result.reference_points.empty(),
                "legacy fallback must not invent modern references");
        require(result.reference_status==ReferencePointStatus::Failed,
                "modern reference failure must remain observable after fallback");
    }
}
void append_u64_le(std::vector<std::uint8_t>& bytes,std::uint64_t value)
{
    for (int i=0;i<8;++i)
        bytes.push_back(static_cast<std::uint8_t>((value>>(8*i))&0xff));
}

void append_f64_le(std::vector<std::uint8_t>& bytes,double value)
{
    std::uint64_t bits=0;
    std::memcpy(&bits,&value,sizeof(bits));
    append_u64_le(bytes,bits);
}

void append_vec3_le(std::vector<std::uint8_t>& bytes,Vec3 p)
{
    append_f64_le(bytes,p.x);
    append_f64_le(bytes,p.y);
    append_f64_le(bytes,p.z);
}

std::uint64_t read_u64_le(const std::vector<std::uint8_t>& bytes,std::size_t index)
{
    require(index+8<=bytes.size(),"Serialized field out of range");
    std::uint64_t result=0;
    for (int i=0;i<8;++i)
        result|=static_cast<std::uint64_t>(bytes[index+i])<<(8*i);
    return result;
}

void test_protocol_v4_preserves_holes_and_triangles()
{
    std::vector<std::uint8_t> bytes{'I','G','M','L','A','D','J',0};
    append_u64_le(bytes,4);   // V4
    append_u64_le(bytes,1);   // One Cell
    append_u64_le(bytes,0);   // Reserved

    constexpr std::size_t face_size=56+4*24+8+4*24+72;
    append_u64_le(bytes,104+face_size);
    append_u64_le(bytes,0);
    append_u64_le(bytes,CELL_FLAG_NEEDS_STATE|CELL_FLAG_ADJACENCY_TARGET);
    append_u64_le(bytes,1); // Face count
    append_u64_le(bytes,0);
    append_vec3_le(bytes,{0,0,0});
    append_vec3_le(bytes,{10,10,1});
    append_f64_le(bytes,0);
    append_u64_le(bytes,static_cast<std::uint64_t>(CellSpaceCategory::Room));

    append_u64_le(bytes,face_size);
    append_u64_le(bytes,4); // outer count
    append_u64_le(bytes,1); // triangle count
    append_u64_le(bytes,1); // inner LOOP count (was reserved in V3)
    append_vec3_le(bytes,{0,0,-1});
    const std::vector<Vec3> outside{{0,0,0},{10,0,0},{10,10,0},{0,10,0}};
    const std::vector<Vec3> hole{{3,3,0},{3,7,0},{7,7,0},{7,3,0}};
    for(const Vec3& p:outside)append_vec3_le(bytes,p);
    append_u64_le(bytes,hole.size());
    for(const Vec3& p:hole)append_vec3_le(bytes,p);
    append_vec3_le(bytes,{0,0,0});
    append_vec3_le(bytes,{10,0,0});
    append_vec3_le(bytes,{0,10,0});

    const auto cells=parse_input_batch(bytes.data(),bytes.size());
    require(cells.size()==1 && cells[0].faces.size()==1,
            "V4 parser lost the Cell/Face");
    const FaceData& face=cells[0].faces.front();
    require(face.outer_points.size()==4 && face.inner_loops.size()==1 &&
            face.inner_loops.front().size()==4 && face.triangles.size()==1,
            "V4 parser lost Outer, Inner, or immutable Triangle geometry");
    require(face.inner_loops.front()[2].x==7 &&
            face.inner_loops.front()[2].y==7 &&
            face.triangles[0].points[1].x==10,
            "V4 parser must retain original coordinate payloads");
}

void test_protocol_v5_decodes_authoritative_plane_and_derives_normal()
{
    std::vector<std::uint8_t> bytes{'I','G','M','L','A','D','J',0};
    append_u64_le(bytes,5); // Geometry V5
    append_u64_le(bytes,1);
    append_u64_le(bytes,0);

    constexpr std::size_t face_size=64+4*24+8+4*24+72;
    append_u64_le(bytes,104+face_size);
    append_u64_le(bytes,0);
    append_u64_le(bytes,CELL_FLAG_NEEDS_STATE|CELL_FLAG_ADJACENCY_TARGET);
    append_u64_le(bytes,1);
    append_u64_le(bytes,0);
    append_vec3_le(bytes,{0,0,7});
    append_vec3_le(bytes,{10,10,8});
    append_f64_le(bytes,0);
    append_u64_le(bytes,static_cast<std::uint64_t>(CellSpaceCategory::Room));

    append_u64_le(bytes,face_size);
    append_u64_le(bytes,4);
    append_u64_le(bytes,1);
    append_u64_le(bytes,1);
    append_vec3_le(bytes,{0,0,-2}); // deliberately nonunit
    append_f64_le(bytes,14);        // -2*z + 14 = 0 => z = 7
    const std::vector<Vec3> outside{
        {0,0,7},{0,10,7},{10,10,7},{10,0,7}
    };
    const std::vector<Vec3> hole{
        {3,3,7},{7,3,7},{7,7,7},{3,7,7}
    };
    for (const Vec3& p:outside) append_vec3_le(bytes,p);
    append_u64_le(bytes,4);
    for (const Vec3& p:hole) append_vec3_le(bytes,p);
    append_vec3_le(bytes,{0,0,7});
    append_vec3_le(bytes,{10,0,7});
    append_vec3_le(bytes,{0,10,7});

    const auto cells=parse_input_batch(bytes.data(),bytes.size());
    require(cells.size()==1 && cells[0].faces.size()==1,
            "V5 Face parser lost source geometry");
    const FaceData& f=cells[0].faces.front();
    require(f.has_plane && std::abs(f.plane.d-7.0)<1.0e-12 &&
            std::abs(f.normal.z+1.0)<1.0e-12 &&
            std::abs(f.plane.normal.z+1.0)<1.0e-12,
            "V5 plane coefficients must normalize with correct D and normal");
    require(f.inner_loops.size()==1 && f.inner_loops[0].size()==4 &&
            f.triangles.size()==1,
            "V5 Plane header must not displace hole loops or triangles");
    const auto prepared=FloorPartition::prepare(
        f.plane,f.outer_loop(),f.holes(),0.001);
    require(bool(prepared) && std::abs(prepared.face->frame.origin.z-7)<1.0e-10,
            "Native partition must use authoritative SketchUp D coefficient");
}

void test_result_v13_encodes_state_and_diagnostics_only()
{
    StatePointResult success;
    success.cell_index=0;
    success.exit_code=StateExitCode::Success;
    success.point=Vec3{1,2,3};
    success.diagnostics.floor_faces=10;
    success.diagnostics.failed_polygons=1;
    success.diagnostics.rejected_outside=2;
    success.diagnostics.accepted_references=9;
    StatePointResult no_state;
    no_state.cell_index=1;
    no_state.exit_code=StateExitCode::OutsideSolid;
    no_state.diagnostics.reference_candidates=2;
    no_state.diagnostics.rejected_outside=2;
    const auto bytes=serialize_state_result_batch({success,no_state});
    require(read_u64_le(bytes,8)==13 && read_u64_le(bytes,16)==2,
            "Result protocol must use V13 and one record per target");
    require(read_u64_le(bytes,32)==0 && read_u64_le(bytes,40)==0 &&
            read_u64_le(bytes,48)==1,
            "V13 success has an explicit State flag");
    require(read_u64_le(bytes,80)==10 &&
            read_u64_le(bytes,104)==1 &&
            read_u64_le(bytes,128)==2 &&
            read_u64_le(bytes,144)==9,
            "V13 diagnostics must retain partial failures with success");

    const std::size_t second=152;
    require(read_u64_le(bytes,second)==1 &&
            read_u64_le(bytes,second+8)==60 &&
            read_u64_le(bytes,second+16)==0 &&
            read_u64_le(bytes,second+24+4*8)==2 &&
            bytes.size()==second+24+9*8,
            "V13 failure must serialize explicit ExitCode and nil State");
    require(bytes.size()==248,
            "V13 State payload must not contain graph nodes or radius");

    bool rejected=false;
    try
    {
        StatePointResult contradiction;
        contradiction.cell_index=0;
        contradiction.point=Vec3{1,2,3};
        contradiction.exit_code=StateExitCode::OutsideSolid;
        (void)serialize_state_result_batch({contradiction});
    }
    catch (const std::invalid_argument&) { rejected=true; }
    require(rejected,"Contradictory ExitCode and State must be rejected");
}

} // namespace

int main()
{
    test_protocol_v4_preserves_holes_and_triangles();
    test_protocol_v5_decodes_authoritative_plane_and_derives_normal();
    test_result_v13_encodes_state_and_diagnostics_only();
    test_z_sweep_matches_bruteforce();
    test_shared_face_analysis();
    test_state_volume_centroid_on_box();
    test_state_concave_u_uses_bvh_fallback();
    test_state_fixed_z();










    test_native_reference_pipeline_bakes_state_tree_and_transition();
    test_non_partitioned_state_is_a_single_node_reference_graph();
    test_reference_short_path_graph_uses_baked_state_tree();
    test_waypoint_anchor_uses_closest_reachable_optimized_node();
    test_native_reference_pipeline_optimizes_degree_two_and_collapses_certificate();
    test_reference_node_roles_have_stage_scoped_protection();
    test_successful_loop_visible_neighbor_is_not_optimization_protected();
    test_collapsed_linearizes_sliver_polygon_components();
    test_optimized_degree_two_angle_threshold_and_priority_queue();
    test_full_los_connects_visible_components_to_state();
    test_full_los_graph_ignores_optimized_edges_and_uses_all_visible_pairs();
    test_connectivity_repair_restores_two_hole_detour_nodes();
    test_full_los_graph_rejects_inherited_edge_through_hole();
    test_disconnected_los_does_not_bridge_through_hole();
    test_convex_floor_one_area_centroid_before();
    test_convex_floor_asymmetric_mesh_has_area_centroid();
    test_coplanar_adjacent_floor_faces_merge();
    test_concave_floor_partitions_without_filling_its_notch();
    test_floor_single_reflex_below_30_degrees_stays_one_region();
    test_floor_single_reflex_over_30_degrees_forces_partition();
    test_floor_many_small_reflex_turns_accumulate();
    test_floor_cumulative_turn_respects_convex_cancellation();
    test_floor_reference_in_short_room_uses_legacy_fallback();
    test_inclined_floor_uses_world_z_not_surface_normal();
    test_floor_hole_does_not_create_void_candidates();
    test_single_floor_face_with_hole_keeps_multiple_regions();
    test_3d_sphere_and_vertical_los();
    test_room_and_stair_both_seed_centroids_and_shared_edges();
    test_single_convex_floor_has_only_one_centroid_for_both();
    test_other_reference_categories_use_legacy_only_after_modern_failure();

    test_room_visibility_graph_circle_overlap_and_blocked_los();
    test_room_reference_shortcut_los_rejects_wall_crossing();
    test_triangle_loop_candidates_are_validated_in_native();
    test_triangle_loop_new_edge_can_cross_non_overlapping_circles();
    test_triangle_loop_new_edges_still_reject_wall_crossings();
    test_four_cycle_native_centroid_and_los_candidate();
    test_tilted_planar_loop_virtual_membrane_is_certified();
    test_warped_four_loop_has_no_unique_membrane();
    test_room_loop_cannot_collapse_over_enclosed_hole();
    test_reference_loop_receives_hole_free_native_certificate();
    return 0;
}
