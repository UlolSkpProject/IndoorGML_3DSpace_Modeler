#include "floor_polygon_reference.h"
#include "floor_face_solid.h"
#include "cell_space_interior_point_locator.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
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

    const auto outside=locate_reference_before(box(10,20),0.001);
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
            "Existing successful Cell must remain exit code 0");
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
            state.state_point.has_value(),
            "Room State must use authoritative plane path without triangles");
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
    // New circles MUST exceed the floor offset without changing State.
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
            "Valid room should still produce the SAME State and BEFORE node");
    require(near(state.debug_graph.nodes.front().radius,100.0-0.001),
            "BEFORE circle radius must use wall distance rather than floor");

    // 1000mm State lies only 0.02" below the ceiling: still the
    // identical wall radius; roof clearance is only used for validity.
    const CellData low_ceiling=box(200,1000.0/25.4+0.02);
    const auto near_roof=locate_reference_before(low_ceiling,0.001);
    require(near_roof.exit_code==StateExitCode::Success &&
            near_roof.debug_graph.nodes.size()==1 &&
            near(near_roof.debug_graph.nodes.front().radius,100.0-0.001),
            "Ceiling clearance must NOT shrink an accepted BEFORE circle");

    // Exceeding the ceiling DOES invalidate State; this safety rule
    // is deliberately independent from circle radius selection.
    const auto outside=locate_reference_before(box(200,20),0.001);
    require(outside.exit_code==StateExitCode::OutsideSolid &&
            !outside.state_point,
            "Wall radius must NOT bypass full-Solid State validation");
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
    require(near(result.debug_graph.nodes.front().radius,0.0),
            "Missing wall Faces must retain a finite serialized radius");
}

void test_single_convex_floor_state_only_before()
{
    const CellData cell=box(20);
    const auto result=locate_reference_before(cell,0.001);
    require(result.state_point.has_value(),"First floor centroid must become State");
    require(result.reference_points.empty(),
            "Promoted first Reference must NOT duplicate the State");
    require(result.debug_graph.nodes.size()==1 &&
            result.debug_graph.edges.empty() &&
            result.debug_graph.loop_candidates.empty(),
            "Single Floor produces a one-node BEFORE Graph without AFTER");
    require(near(result.state_point->x,10.0) &&
            near(result.state_point->y,10.0) &&
            near(result.state_point->z,1000.0/25.4),
            "State must be the floor centroid raised by world Z +1000mm");
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
            "Stair State and BEFORE must follow the same Reference policy");
    require(result.debug_graph.loop_candidates.empty(),
            "Stair BEFORE must never create collapse certificates");
}
void test_before_rejects_sphere_radius_below_150mm()
{
    const auto result=locate_reference_before(box(10),0.001);
    require(!result.state_point.has_value() &&
            result.exit_code==StateExitCode::NoReferenceCandidates,
            "Sphere radius below 150mm must be rejected before BEFORE");
    require(result.debug_graph.nodes.empty() &&
            result.diagnostics.accepted_references==0,
            "Rejected small sphere must not leak into the BEFORE graph");
}
void test_short_room_has_no_reference_state()
{
    const auto cell=box(10,20); // +1000 mm lies ABOVE ceiling
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
    test_single_convex_floor_state_only_before();
    test_l_floor_queue_and_state_promoted_without_triangles();
    test_shared_boundary_midpoint_without_matching_tessellation();
    test_shared_edge_with_mismatched_vertex_splits_merges_once();
    test_stair_uses_same_first_reference_policy();
    test_before_rejects_sphere_radius_below_150mm();
    test_short_room_has_no_reference_state();
    test_hole_queue_and_failed_diagnostics();
    return 0;
}
