#include "cell_space_interior_point_locator.h"
#include "floor_face_solid.h"
#include "floor_reference_loops.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>

using namespace IndoorGMLAdjacencyNative;
namespace
{
void require(bool passed,const char* message)
{
    if(!passed){std::cerr<<message<<'\n';std::exit(1);}
}
FaceData face(Vec3 normal,std::vector<Vec3> outer,
              std::vector<std::vector<Vec3>> holes={})
{
    FaceData result;
    result.normal=normal;
    result.outer_points=std::move(outer);
    result.inner_loops=std::move(holes);
    return result;
}
CellData room(bool shaft)
{
    CellData cell;
    cell.category=CellSpaceCategory::Room;
    cell.bounds={{0,0,0},{10,10,10}};
    const Vec3 a{0,0,0},b{10,0,0},c{10,10,0},d{0,10,0};
    const Vec3 A{0,0,10},B{10,0,10},C{10,10,10},D{0,10,10};
    const std::vector<Vec3> lower_hole{{4,4,0},{6,4,0},{6,6,0},{4,6,0}};
    const std::vector<Vec3> upper_hole{{4,4,10},{6,4,10},{6,6,10},{4,6,10}};
    cell.faces={
        face({0,0,-1},{a,d,c,b},shaft?std::vector<std::vector<Vec3>>{lower_hole}:std::vector<std::vector<Vec3>>{}),
        face({0,0,1},{A,B,C,D},shaft?std::vector<std::vector<Vec3>>{upper_hole}:std::vector<std::vector<Vec3>>{}),
        face({0,-1,0},{a,b,B,A}),face({1,0,0},{b,c,C,B}),
        face({0,1,0},{c,d,D,C}),face({-1,0,0},{d,a,A,D})
    };
    if(shaft)
    {
        cell.faces.push_back(face({1,0,0},{{4,4,0},{4,6,0},{4,6,10},{4,4,10}}));
        cell.faces.push_back(face({-1,0,0},{{6,4,0},{6,4,10},{6,6,10},{6,6,0}}));
        cell.faces.push_back(face({0,1,0},{{4,4,0},{4,4,10},{6,4,10},{6,4,0}}));
        cell.faces.push_back(face({0,-1,0},{{4,6,0},{6,6,0},{6,6,10},{4,6,10}}));
    }
    return cell;
}
ReferenceGraphDebug square_graph()
{
    ReferenceGraphDebug graph;
    graph.nodes={
        {{1,1,5},1},{{2,2,5},2},{{8,2,5},2},
        {{8,8,5},2},{{2,8,5},2}
    };
    graph.edges={{1,2},{2,3},{3,4},{1,4}};
    return graph;
}
void test_hole_free_square_is_certified()
{
    FaceSolid solid(room(false),0.001);
    require(solid.valid(),"Unobstructed room must be valid");
    auto graph=square_graph();
    certify_before_reference_loops(solid,graph,0.001);
    require(graph.loop_candidates.size()==1,"Hole-free four-cycle must be certified");
    const auto& cert=graph.loop_candidates.front();
    require(cert.vertices==std::vector<std::size_t>({1,2,3,4}),"Ordered ring must be deterministic");
    require(cert.visible_neighbors.empty(),"Isolated ring has no boundary neighbors");
    require(solid.inside(cert.representative.point,0.001),"Representative must be inside Solid");
    require(cert.representative.radius>0,"Representative clearance must be positive");
    require(graph.nodes.size()==5&&graph.edges.size()==4,"BEFORE must not be modified");
}
void test_shaft_crossing_membrane_rejects_loop()
{
    FaceSolid solid(room(true),0.001);
    require(solid.valid(),"Inner-shaft room must be represented by Face loops");
    auto graph=square_graph();
    certify_before_reference_loops(solid,graph,0.001);
    require(graph.loop_candidates.empty(),"Shaft boundary crossing membrane MUST reject certificate");
    require(graph.nodes.size()==5&&graph.edges.size()==4,"Rejected loop leaves BEFORE intact");
}
void test_chorded_and_nonplanar_loop_rejected()
{
    FaceSolid solid(room(false),0.001);
    auto chorded=square_graph();
    chorded.edges.push_back({1,3});
    certify_before_reference_loops(solid,chorded,0.001);
    for(const auto& cert:chorded.loop_candidates)
        require(cert.vertices.size()!=4,"Chorded quadrilateral cannot be certified");
    auto warped=square_graph();
    warped.nodes[3].point.z+=2;
    certify_before_reference_loops(solid,warped,0.001);
    require(warped.loop_candidates.empty(),"Nonplanar ring must be refused");
}
void test_over_415_nodes_does_not_disable_detection()
{
    FaceSolid solid(room(false),0.001);
    auto graph=square_graph();
    for(int i=0;i<420;++i)
        graph.nodes.push_back({{0.5,0.5,5},0.1});
    certify_before_reference_loops(solid,graph,0.001);
    require(graph.loop_candidates.size()==1,
            "Number of unrelated graph nodes must not disable bounded cycle detection");
}
}
int main()
{
    test_hole_free_square_is_certified();
    test_shaft_crossing_membrane_rejects_loop();
    test_chorded_and_nonplanar_loop_rejected();
    test_over_415_nodes_does_not_disable_detection();
    std::cout<<"BEFORE Loop certificates: OK\n";
}
