#include "floor_polygon_reference.h"
#include "floor_face_solid.h"
#include "cell_space_interior_point_locator.h"
#include "reference_graph_pipeline.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

using namespace IndoorGMLAdjacencyNative;
using namespace IndoorGMLAdjacencyNative::FloorPartition;

namespace
{
void require(bool condition,const char* message)
{
    if (!condition) { std::cerr<<message<<'\n';std::exit(1); }
}
bool near(double a,double b,double tol=1.0e-6)
{
    return std::abs(a-b)<=tol;
}
FaceData face(Vec3 normal,const std::vector<Vec3>& outer,
              const std::vector<std::vector<Vec3>>& holes={})
{
    FaceData f;
    f.normal=normal;
    f.outer_points=outer;
    f.inner_loops=holes;
    // Key regression: the entire pipeline runs with NO triangles.
    return f;
}
CellData box(double width=10,double height=80)
{
    const double w=width,h=height;
    const Vec3 a{0,0,0},b{w,0,0},c{w,w,0},d{0,w,0};
    const Vec3 A{0,0,h},B{w,0,h},C{w,w,h},D{0,w,h};
    CellData cell;
    cell.category=CellSpaceCategory::Room;
    cell.flags=CELL_FLAG_NEEDS_STATE;
    cell.bounds={{0,0,0},{w,w,h}};
    cell.faces={
        face({0,0,-1},{a,d,c,b}),
        face({0,0,1},{A,B,C,D}),
        face({0,-1,0},{a,b,B,A}),
        face({1,0,0},{b,c,C,B}),
        face({0,1,0},{c,d,D,C}),
        face({-1,0,0},{d,a,A,D})
    };
    return cell;
}
std::vector<Vec3> rectangle(double x0,double y0,double x1,double y1)
{
    return {{x0,y0,0},{x1,y0,0},{x1,y1,0},{x0,y1,0}};
}
NormalizedFace normal_face(const std::vector<Vec3>& outer,
                           const std::vector<std::vector<Vec3>>& holes={})
{
    const auto result=prepare(Vec3{0,0,-1},outer,holes,0.001);
    require(result.face.has_value(),"Test polygon preparation failed");
    return *result.face;
}
void test_exit_code_failure_stage_distinctions()
{
    const auto valid=box();
    require(locate_reference_before(valid,0.0).exit_code==
                StateExitCode::InvalidInput,
            "Nonpositive tolerance must report invalid input");

    auto no_floor=valid;
    for (FaceData& f:no_floor.faces)f.normal={0,0,1};
    const auto floorless=locate_reference_before(no_floor,0.001);
    require(floorless.exit_code==StateExitCode::NoFloorFaces &&
            floorless.diagnostics.floor_faces==0,
            "No downward Floor must return NO_FLOOR");

    auto invalid_floor=valid;
    invalid_floor.faces[0].outer_points.resize(2);
    const auto bad_floor=locate_reference_before(invalid_floor,0.001);
    require(bad_floor.exit_code==StateExitCode::FloorPreparationFailed &&
            bad_floor.diagnostics.floor_faces==1 &&
            bad_floor.diagnostics.prepared_faces==0,
            "Malformed Floor should not be obscured by Solid BVH creation");

    auto bad_solid=valid;
    bad_solid.faces[2].outer_points.resize(2);
    const auto invalid_solid=locate_reference_before(bad_solid,0.001);
    require(invalid_solid.exit_code==StateExitCode::InvalidSolidGeometry &&
            invalid_solid.diagnostics.prepared_faces==1,
            "Invalid nonfloor Face must report the Solid geometry stage");

    const auto outside=locate_reference_before(box(10,10),0.001);
    require(outside.exit_code==StateExitCode::OutsideSolid &&
            outside.diagnostics.reference_candidates>=1 &&
            outside.diagnostics.rejected_outside>=1,
            "1000 mm above a low ceiling should report OUTSIDE_SOLID");

    const auto near_ceiling=locate_reference_before(
        box(10,1000.0/25.4+0.0005),0.001);
    require(near_ceiling.exit_code==StateExitCode::InsufficientClearance &&
            near_ceiling.diagnostics.rejected_clearance>=1,
            "Boundary-near reference should report insufficient clearance");

    const auto success=locate_reference_before(box(20),0.001);
    require(success.exit_code==StateExitCode::Success &&
            success.state_point.has_value() &&
            success.diagnostics.accepted_references>=1,
            "Successful BEFORE must return State and remain exit code 0");
    require(success.debug_graph.floor_partitions.size()==1 &&
            success.debug_graph.floor_partitions.front().outer.size()==4 &&
            success.debug_graph.floor_partitions.front().holes.empty(),
            "BEFORE debug result must preserve the completed Floor partition");
}

void test_face_bvh_uses_plane_from_source()
{
    auto cell=box(20);
    for (FaceData& f:cell.faces)
    {
        f.has_plane=true;
        const Vec3 point=f.outer_points.front();
        f.plane={f.normal,-(f.normal.x*point.x+f.normal.y*point.y+f.normal.z*point.z)};
    }
    FaceSolid solid(cell,0.001);
    require(solid.valid() && solid.inside({5,5,39},0.001),
            "Face BVH must accept FaceData.plane with preserved orientation");
    const auto state=locate_reference_before(cell,0.001);
    require(state.exit_code==StateExitCode::Success &&
            state.state_point.has_value() &&
            state.debug_graph.nodes.size()==1,
            "Room BEFORE must use authoritative plane path without triangles");
}

void test_box_face_bvh_without_triangles()
{
    const CellData cell=box();
    FaceSolid solid(cell,0.001);
    require(solid.valid(),"Loop-only cube must form a valid Face BVH");
    require(solid.inside({5,5,39},0.001),"Solid center must be inside");
    require(!solid.inside({15,5,39},0.001),"Outside point must be rejected");
    require(near(solid.nearest_distance({5,5,39}),5.0),
            "Point-to-polygon boundary distance must include wall surfaces");
    require(solid.visible({5,5,25},{5,5,50},0.001),
            "Unblocked vertical LOS must be accepted");
    require(!solid.visible({5,5,25},{15,5,25},0.001),
            "LOS leaving solid must be rejected");
}
void test_before_radius_ignores_floor_and_ceiling()
{
    // Wide enclosed room: floor is ~39.37" away, walls are 100" away.
    // New circles MUST exceed the floor offset without creating State.
    const CellData room=box(200,80);
    FaceSolid solid(room,0.001);
    const Vec3 reference{100,100,1000.0/25.4};
    require(solid.inside(reference,0.001),
            "Wall-radius reference must still pass full 3D Solid containment");
    require(solid.nearest_distance(reference)<40,
            "Full Solid clearance should remain floor-limited");
    require(near(solid.nearest_wall_distance(reference),100.0),
            "Wall-only BVH must skip floor and ceiling Faces");
    require(near(solid.nearest_wall_distance({2,100,1000.0/25.4}),2.0),
            "Wall-only radius must still respect a nearby vertical wall");

    const auto state=locate_reference_before(room,0.001);
    require(state.exit_code==StateExitCode::Success &&
            state.state_point.has_value() &&
            state.debug_graph.nodes.size()==1,
            "Valid room should produce one BEFORE node and State");
    require(near(state.debug_graph.nodes.front().radius,100.0-0.001),
            "BEFORE circle radius must use wall distance rather than floor");

    // 1000mm reference lies only 0.02" below the ceiling: still the
    // identical wall radius; roof clearance is only used for validity.
    const CellData low_ceiling=box(200,1000.0/25.4+0.02);
    const auto near_roof=locate_reference_before(low_ceiling,0.001);
    require(near_roof.exit_code==StateExitCode::Success &&
            near_roof.debug_graph.nodes.size()==1 &&
            near(near_roof.debug_graph.nodes.front().radius,100.0-0.001),
            "Ceiling clearance must NOT shrink an accepted BEFORE circle");

    // Exceeding the ceiling DOES invalidate the reference; this safety rule
    // is deliberately independent from circle radius selection.
    const auto outside=locate_reference_before(box(200,20),0.001);
    require(outside.exit_code==StateExitCode::OutsideSolid &&
            !outside.state_point,
            "Wall radius must NOT bypass full-Solid reference validation");
}
void test_no_wall_query_remains_safe()
{
    CellData cell;
    cell.faces={face({0,0,-1},{
        {0,0,0},{0,10,0},{10,10,0},{10,0,0}
    })};
    FaceSolid solid(cell,0.001);
    require(solid.valid(),
            "A Face with no wall still builds its standard Solid BVH");
    require(std::isinf(solid.nearest_wall_distance({5,5,3})),
            "No wall faces must yield infinity instead of floor distance");
    require(near(solid.nearest_distance({5,5,3}),3),
            "Existing all-face distance must remain unchanged");
}
void test_no_wall_solid_keeps_reference_candidate()
{
    const Vec3 a{0,0,0},b{200,0,0},c{200,200,0},d{0,200,0};
    const Vec3 apex{100,100,80};
    CellData cell;
    cell.category=CellSpaceCategory::Room;
    cell.flags=CELL_FLAG_NEEDS_STATE;
    cell.bounds={{0,0,0},{200,200,80}};
    cell.faces={
        face({0,0,-1},{a,d,c,b}),
        face({0,-16000,20000},{a,b,apex}),
        face({16000,0,20000},{b,c,apex}),
        face({0,16000,20000},{c,d,apex}),
        face({-16000,0,20000},{d,a,apex})
    };

    FaceSolid solid(cell,0.001);
    const Vec3 candidate{100,100,1000.0/25.4};
    require(solid.valid() && solid.inside(candidate,0.001),
            "Sloped no-wall fixture must contain its floor reference");
    require(std::isinf(solid.nearest_wall_distance(candidate)),
            "Steep sloped Faces must not become wall-radius constraints");

    const auto result=locate_reference_before(cell,0.001);
    require(result.exit_code==StateExitCode::Success &&
            result.state_point.has_value() &&
            result.debug_graph.nodes.size()==1,
            "Missing wall Faces must not reject an otherwise valid reference");
    require(std::isinf(result.debug_graph.nodes.front().radius),
            "Missing wall Faces must retain infinite Native radius");
}

void test_single_convex_floor_reference_only_before()
{
    const CellData cell=box(20);
    const auto result=locate_reference_before(cell,0.001);
    require(result.state_point.has_value(),
            "BEFORE must select the valid polygon centroid as State");
    require(result.reference_points.size()==1,
            "Single Floor centroid must remain a reference");
    require(result.debug_graph.nodes.size()==1 &&
            result.debug_graph.edges.empty() &&
            result.debug_graph.loop_candidates.empty(),
            "Single Floor produces a one-node BEFORE Graph without AFTER");
    const Vec3& point=result.reference_points.front().point;
    require(near(point.x,10.0) && near(point.y,10.0) &&
            near(point.z,1000.0/25.4),
            "Reference must be the floor centroid raised by world Z +1000mm");
}
void test_l_floor_queue_and_state_promoted_without_triangles()
{
    const auto l=std::vector<Vec3>{
        {0,0,0},{8,0,0},{8,2,0},
        {2,2,0},{2,8,0},{0,8,0}
    };
    const auto normalized=normal_face(l);
    const auto queue=partition_queue(normalized,0,0.001);
    require(queue.accepted_splits>=1 && queue.completed.size()>=2,
            "L-shaped floor must be partitioned through Queue");
    const auto refs=generate_reference_seeds(queue.completed,0.001);
    require(refs.points.size()>=3 && refs.shared_segments>=1,
            "Two L partitions must yield centroids and a shared-edge midpoint");
    // Check that no new partitioning code mutates original Face geometry.
    require(l.size()==6 && l[3].x==2 && l[3].y==2,
            "Queue partitioning must leave source immutable");
}
CellData l_shaped_room()
{
    const std::vector<Vec3> floor{
        {0,0,0},{64,0,0},{64,20,0},
        {20,20,0},{20,64,0},{0,64,0}
    };
    CellData cell;
    cell.category=CellSpaceCategory::Room;
    cell.flags=CELL_FLAG_NEEDS_STATE;
    cell.bounds={{0,0,0},{64,64,80}};

    std::vector<Vec3> bottom(floor.rbegin(),floor.rend());
    cell.faces.push_back(face({0,0,-1},bottom));

    std::vector<Vec3> ceiling;
    for (Vec3 p:floor) ceiling.push_back({p.x,p.y,80});
    cell.faces.push_back(face({0,0,1},ceiling));
    for (std::size_t i=0;i<floor.size();++i)
    {
        const Vec3 a=floor[i],b=floor[(i+1)%floor.size()];
        const Vec3 A{a.x,a.y,80},B{b.x,b.y,80};
        cell.faces.push_back(face({b.y-a.y,a.x-b.x,0},{a,b,B,A}));
    }
    return cell;
}
void test_before_selects_nearest_valid_seed_and_retains_orphan_centroids()
{
    const CellData cell=l_shaped_room();
    const double tolerance=0.001;
    const FaceSolid solid(cell,tolerance);
    require(solid.valid(),"L-shaped regression fixture must be a valid Solid");
    const auto result=locate_reference_before(cell,tolerance);
    require(result.exit_code==StateExitCode::Success &&
            result.state_point.has_value() &&
            result.debug_graph.state_node_index.has_value(),
            "State must exist with an explicit BEFORE node index");

    // Rebuild seed positions from the recorded final partitions, then apply
    // the validation and filtering contract independently of BEFORE output.
    std::vector<PartitionLeaf> leaves;
    for (const auto& partition:result.debug_graph.floor_partitions)
    {
        const auto normalized=prepare(
            Vec3{0,0,-1},partition.outer,partition.holes,tolerance);
        require(normalized.face.has_value(),"Recorded polygon must re-prepare");
        leaves.push_back({0,leaves.size(),*normalized.face});
    }
    require(leaves.size()>1,"L-shaped Floor cannot convex-coarsen to one polygon");
    const auto seeds=generate_reference_seeds(leaves,tolerance);
    struct Accepted {
        const Seed* seed;
    };
    std::vector<Accepted> accepted;
    std::vector<bool> has_valid_shared(leaves.size(),false);
    for (const auto& seed:seeds.points)
    {
        const double clearance=solid.nearest_distance(seed.position);
        if (!std::isfinite(clearance) || clearance<=tolerance ||
            !solid.inside(seed.position,tolerance)) continue;
        const double wall=solid.nearest_wall_distance(seed.position);
        if (std::isfinite(wall) && std::max(0.0,wall-tolerance)<150.0/25.4)
            continue;
        accepted.push_back({&seed});
        if (seed.kind==SeedKind::SharedEdgeMidpoint)
        {
            has_valid_shared[seed.first_leaf]=true;
            has_valid_shared[seed.second_leaf]=true;
        }
    }
    require(!accepted.empty(),"Fixture must have valid reference seeds");

    const Vec3 center{32,32,40};
    std::size_t state=0;
    double shortest=std::numeric_limits<double>::infinity();
    for (std::size_t i=0;i<accepted.size();++i)
    {
        const Vec3& p=accepted[i].seed->position;
        const double squared_distance=
            (p.x-center.x)*(p.x-center.x)+
            (p.y-center.y)*(p.y-center.y)+
            (p.z-center.z)*(p.z-center.z);
        if (squared_distance<shortest)
        {
            shortest=squared_distance;
            state=i;
        }
    }

    std::vector<Vec3> expected;
    std::size_t expected_state_index=accepted.size();
    for (std::size_t i=0;i<accepted.size();++i)
    {
        const Seed& seed=*accepted[i].seed;
        const bool is_state=i==state;
        if (is_state || seed.kind==SeedKind::SharedEdgeMidpoint ||
            (seed.kind==SeedKind::PolygonCentroid &&
             !has_valid_shared[seed.first_leaf]))
        {
            if (is_state) expected_state_index=expected.size();
            expected.push_back(seed.position);
        }
    }
    require(expected_state_index<expected.size(),
            "The selected State must survive reference filtering");
    require(result.debug_graph.state_node_index==expected_state_index,
            "State index must track its filtered node position, not always zero");
    require(result.debug_graph.nodes.size()==expected.size(),
            "BEFORE must retain exactly State, valid shared and orphan centroids");
    for (std::size_t i=0;i<expected.size();++i)
    {
        const Vec3 actual=result.debug_graph.nodes[i].point;
        require(near(actual.x,expected[i].x) &&
                near(actual.y,expected[i].y) &&
                near(actual.z,expected[i].z),
                "BEFORE must preserve original validated reference ordering");
    }
    const Vec3 selected=expected[expected_state_index];
    require(near(result.state_point->x,selected.x) &&
            near(result.state_point->y,selected.y) &&
            near(result.state_point->z,selected.z),
            "State must be the nearest valid centroid or shared-edge midpoint");
}
void test_reference_graph_routes_from_nonzero_state_node()
{
    const CellData cell=box(20);
    const double z=1000.0/25.4;
    ReferenceGraphDebug before;
    before.nodes={
        {{6,10,z},6},
        {{14,10,z},6}
    };
    before.edges={{0,1}};
    before.state_node_index=1;

    const auto pipeline=build_reference_graph_pipeline(cell,before,0.001);
    require(pipeline.before.nodes.size()==2 &&
            pipeline.optimized.nodes.size()==2,
            "Reducing a protected two-node graph must retain both nodes");
    require(pipeline.state_node_index==1 &&
            pipeline.shortest_path_tree.root==1,
            "Native graph and shortest-path tree must use a nonzero State index");
    require(pipeline.after.protected_nodes[1] &&
            pipeline.shortest_path_tree.distances[1]==0.0 &&
            std::isfinite(pipeline.shortest_path_tree.distances[0]),
            "Nonzero State must remain protected and reach the other node");
    const auto path=reference_transition_polyline(
        pipeline,Vec3{15,11,z});
    require(path.size()==2 &&
            near(path.front().x,14.0) &&
            near(path.back().x,15.0),
            "Transition routing must start from the selected nonzero State node");
}
CellData l_shaped_reference_room()
{
    const double height=80.0;
    const std::vector<Vec3> base{
        {0,0,0},{40,0,0},{40,10,0},
        {10,10,0},{10,40,0},{0,40,0}
    };
    std::vector<Vec3> roof=base;
    for(auto& p:roof) p.z=height;
    std::vector<Vec3> bottom=base;
    std::reverse(bottom.begin(),bottom.end());
    CellData cell;
    cell.category=CellSpaceCategory::Room;
    cell.bounds={{0,0,0},{40,40,height}};
    cell.faces.push_back(face({0,0,-1},bottom));
    cell.faces.push_back(face({0,0,1},roof));
    for(std::size_t i=0;i<base.size();++i)
    {
        const Vec3& a=base[i];
        const Vec3& b=base[(i+1)%base.size()];
        const double wall_length=std::hypot(b.x-a.x,b.y-a.y);
        cell.faces.push_back(face(
            {(b.y-a.y)/wall_length,(a.x-b.x)/wall_length,0},
            {a,b,{b.x,b.y,height},{a.x,a.y,height}}
        ));
    }
    return cell;
}

void test_waypoint_gateway_uses_los_and_total_state_cost()
{
    const CellData cell=l_shaped_reference_room();
    const double z=1000.0/25.4;
    const Vec3 state{5,30,z};
    const Vec3 far_gateway{5,5,z};
    const Vec3 near_gateway{35,5,z};
    const Vec3 waypoint{40,5,z}; // Exact shared-Face boundary
    ReferenceGraphPipeline pipeline;
    pipeline.optimized.nodes={
        {state,0.0},{near_gateway,0.0},{far_gateway,0.0}
    };
    pipeline.shortest_path_tree.root=0;
    pipeline.shortest_path_tree.distances={0.0,80.0,25.0};
    pipeline.shortest_path_tree.previous={std::nullopt,0,0};
    pipeline.waypoint_solid=std::make_shared<FaceSolid>(cell,0.001);
    pipeline.waypoint_tolerance=0.001;

    require(pipeline.waypoint_solid->valid(),
            "L-shaped Solid must be usable for persistent waypoint LOS");
    const auto path=reference_transition_polyline(pipeline,waypoint);
    require(path.size()==3 && near(path[1].x,5.0) &&
            near(path.back().x,40.0),
            "Gateway must minimize LOS-direct plus State shortest-path cost, "
            "not raw waypoint distance; boundary waypoint must remain exact");

    pipeline.shortest_path_tree.distances[1]=35.0;
    const auto shorter=reference_transition_polyline(pipeline,waypoint);
    require(shorter.size()==3 && near(shorter[1].x,35.0),
            "A shorter total State route must select the nearer LOS gateway");

    require(reference_transition_polyline(
                pipeline,Vec3{50,50,z}).empty(),
            "Waypoint outside the CellSpace without visible gateways must fail closed");
}
void test_legacy_state_only_route_survives_invalid_solid()
{
    CellData legacy_cell;
    const Vec3 state{1,2,3};
    const auto pipeline=build_state_reference_graph_pipeline(
        state,legacy_cell,0.001);
    require(pipeline.legacy_state_only && !pipeline.waypoint_solid->valid(),
            "Legacy fallback fixture must retain its explicit State-only route");
    const auto path=reference_transition_polyline(pipeline,Vec3{4,5,6});
    require(path.size()==2 && near(path[0].x,1.0) && near(path[1].x,4.0),
            "Invalid legacy Solid must not regress the prior State-only route");
}
void test_reference_local_finalization_uses_actual_post_state_frame()
{
    const CellData cell=box(20);
    const double z=1000.0/25.4;
    ReferenceGraphDebug before;
    before.nodes={{{10,10,z},6},{{12,10,z},6}};
    before.edges={{0,1}};
    before.state_node_index=0;
    const auto original=build_reference_graph_pipeline(cell,before,0.001);
    const std::array<double,16> snapped_inverse={
        1,0,0,0, 0,1,0,0, 0,0,1,0,
        -10.00001,-10,-z,1
    };
    auto pipeline=original;
    finalize_reference_graph_local(pipeline,cell,snapped_inverse);
    for(const auto* stage:{&pipeline.before,&pipeline.after,
                           &pipeline.collapsed,&pipeline.optimized})
    {
        require(!stage->nodes.empty() &&
                near(stage->nodes[0].point.x,-0.00001,1e-8) &&
                near(stage->nodes[0].point.y,0.0,1e-8),
                "Every Reference stage must use the final snapped Local frame");
    }
    require(pipeline.waypoint_solid->valid() &&
            pipeline.waypoint_solid->inside(pipeline.optimized.nodes[0].point,0.001),
            "Waypoint FaceSolid must share the nodes' final Local frame");
    require(near(pipeline.shortest_path_tree.distances[1],
                 original.shortest_path_tree.distances[1]),
            "Rigid recenter must preserve the State shortest-path weights");

    const std::array<double,16> rotated_inverse={
        0,-1,0,0, 1,0,0,0, 0,0,1,0, 0,0,0,1
    };
    auto rotated=original;
    finalize_reference_graph_local(rotated,cell,rotated_inverse);
    require(near(rotated.optimized.nodes[0].point.x,10.0) &&
            near(rotated.optimized.nodes[0].point.y,-10.0) &&
            rotated.waypoint_solid->inside(rotated.optimized.nodes[0].point,0.001),
            "CellSpace rotation must transform both the graph and LOS Solid");
    const auto route=reference_transition_polyline(rotated,{10,-20,z});
    require(!route.empty() && near(route.back().y,-20.0),
            "Local waypoint routing must work after CellSpace rotation");

    auto invalid=original;
    auto scaled=snapped_inverse;
    scaled[0]=2.0;
    bool rejected=false;
    try { finalize_reference_graph_local(invalid,cell,scaled); }
    catch(const std::invalid_argument&) { rejected=true; }
    require(rejected,"Non-rigid CellSpace frame must be rejected");
}
void test_shared_boundary_midpoint_without_matching_tessellation()
{
    const auto left=normal_face(rectangle(0,0,4,4));
    const auto right=normal_face(rectangle(4,0,8,4));
    const std::vector<PartitionLeaf> leaves{
        {0,0,left},{0,1,right}
    };
    const auto refs=generate_reference_seeds(leaves,0.001);
    require(refs.shared_segments==1 && refs.points.size()==3,
            "Two adjacent quads must generate 2 centroids and 1 midpoint");
    const auto& mid=refs.points.back().position;
    require(near(mid.x,4)&&near(mid.y,2),
            "Shared-edge seed must lie at the exact boundary midpoint");
}
void test_shared_edge_with_mismatched_vertex_splits_merges_once()
{
    const auto first=normal_face({
        {0,0,0},{4,0,0},{4,1,0},{4,4,0},{0,4,0}
    });
    const auto second=normal_face({
        {4,0,0},{8,0,0},{8,4,0},{4,4,0},{4,3,0}
    });
    const std::vector<PartitionLeaf> leaves{
        {0,0,first},{0,0,second}
    };
    const auto result=generate_reference_seeds(leaves,0.001);
    require(result.shared_segments==1 && result.points.size()==3,
            "Collinear T-junction fragments must merge into ONE shared edge");
    const auto& middle=result.points.back().position;
    require(near(middle.x,4.0)&&near(middle.y,2.0),
            "Merged edge midpoint must be independent of Vertex splits");
}
void test_stair_uses_same_first_reference_policy()
{
    auto cell=box(20);
    cell.category=CellSpaceCategory::Stair;
    const auto result=locate_reference_before(cell,0.001);
    require(result.state_point.has_value() &&
            result.debug_graph.nodes.size()==1,
            "Stair must select State and follow the same BEFORE policy");
    require(result.debug_graph.loop_candidates.empty(),
            "Stair BEFORE must never create collapse certificates");
}
void test_category_height_and_radius_policies()
{
    for (const CellSpaceCategory category : {
             CellSpaceCategory::Room,CellSpaceCategory::Stair,
             CellSpaceCategory::Elevator})
    {
        CellData cell=box(20,80);
        cell.category=category;
        const auto result=locate_reference_before(cell,0.001);
        require(result.exit_code==StateExitCode::Success &&
                result.state_point.has_value() &&
                near(result.state_point->z,1000.0/25.4),
                "Room/Stair/Elevator must use the +1000mm Floor policy");
    }

    CellData narrow_room=box(4,80);
    narrow_room.category=CellSpaceCategory::Room;
    require(locate_reference_before(narrow_room,0.001).exit_code==
                StateExitCode::InsufficientClearance,
            "Room must retain the 150mm wall-radius threshold");

    CellData door=narrow_room;
    door.category=CellSpaceCategory::Door;
    const auto door_result=locate_reference_before(door,0.001);
    require(door_result.exit_code==StateExitCode::Success &&
            door_result.state_point.has_value() &&
            near(door_result.state_point->z,1000.0/25.4),
            "Door must use +1000mm with the relaxed 30mm radius");

    CellData window=narrow_room;
    window.category=CellSpaceCategory::Window;
    const auto window_result=locate_reference_before(window,0.001);
    require(window_result.exit_code==StateExitCode::Success &&
            window_result.state_point.has_value() &&
            near(window_result.state_point->z,40.0),
            "Window must use half the height to its first ceiling");
}
void test_before_rejects_sphere_radius_below_150mm()
{
    const auto result=locate_reference_before(box(10),0.001);
    require(!result.state_point.has_value() &&
            result.exit_code==StateExitCode::InsufficientClearance &&
            result.diagnostics.rejected_clearance==1,
            "Sphere radius below 150mm must be rejected before BEFORE");
    require(result.debug_graph.nodes.empty() &&
            result.diagnostics.accepted_references==0,
            "Rejected small sphere must not leak into the BEFORE graph");
}
void test_short_room_has_no_reference_state()
{
    const auto cell=box(10,10); // +1000 mm lies ABOVE ceiling
    const auto result=locate_reference_before(cell,0.001);
    require(!result.state_point.has_value(),
            "No valid 1000mm Reference means explicit no-State result");
    require(result.debug_graph.nodes.empty(),
            "Failure must not fabricate a BEFORE Graph");
}
void test_hole_queue_and_failed_diagnostics()
{
    const auto prepared=normal_face(
        rectangle(0,0,12,12),
        {rectangle(3,3,5,5)});
    const auto batch=partition_queue(prepared,0,0.001);
    require(batch.attempted_splits>0,
            "Hole-bearing Face must enter the split Queue");
    require(batch.completed.size()+batch.failed.size()>0,
            "Each queued domain must finish or remain as a debug failure");
    for (const auto& failure:batch.failed)
        require(!failure.rejected_candidates.empty() ||
                failure.invalid_child || failure.limit_exceeded,
                "Unsplit polygons must retain a concrete debug reason");
}
}
int main()
{
    test_exit_code_failure_stage_distinctions();
    test_face_bvh_uses_plane_from_source();
    test_box_face_bvh_without_triangles();
    test_before_radius_ignores_floor_and_ceiling();
    test_no_wall_query_remains_safe();
    test_no_wall_solid_keeps_reference_candidate();
    test_single_convex_floor_reference_only_before();
    test_l_floor_queue_and_state_promoted_without_triangles();
    test_before_selects_nearest_valid_seed_and_retains_orphan_centroids();
    test_reference_graph_routes_from_nonzero_state_node();
    test_waypoint_gateway_uses_los_and_total_state_cost();
    test_legacy_state_only_route_survives_invalid_solid();
    test_reference_local_finalization_uses_actual_post_state_frame();
    test_shared_boundary_midpoint_without_matching_tessellation();
    test_shared_edge_with_mismatched_vertex_splits_merges_once();
    test_stair_uses_same_first_reference_policy();
    test_category_height_and_radius_policies();
    test_before_rejects_sphere_radius_below_150mm();
    test_short_room_has_no_reference_state();
    test_hole_queue_and_failed_diagnostics();
    return 0;
}
