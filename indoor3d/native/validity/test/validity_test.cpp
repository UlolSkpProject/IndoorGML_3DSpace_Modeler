#include "validity_checker.h"

#include <manifold/manifold.h>

#include <cmath>
#include <cstdlib>
#include <iostream>

namespace
{
using namespace IndoorGMLAdjacencyNative;
using namespace IndoorGMLValidityNative;

void require(bool condition,const char* message)
{
    if (!condition)
    {
        std::cerr << message << std::endl;
        std::exit(1);
    }
}

Triangle triangle(Vec3 a,Vec3 b,Vec3 c)
{
    return Triangle{{a,b,c}};
}

FaceData square_z_face(
    double min_x,double max_x,double min_y,double max_y,double z,double normal_z
)
{
    const Vec3 p0{min_x,min_y,z};
    const Vec3 p1{max_x,min_y,z};
    const Vec3 p2{max_x,max_y,z};
    const Vec3 p3{min_x,max_y,z};

    FaceData face;
    face.normal={0.0,0.0,normal_z};
    face.outer_points={p0,p1,p2,p3};
    face.triangles={
        triangle(p0,p1,p2),
        triangle(p0,p2,p3)
    };
    return face;
}

CellData face_cell(
    std::size_t index,
    double min_x,double max_x,double min_y,double max_y,
    double normal_z
)
{
    CellData cell;
    cell.index=index;
    cell.bounds.minimum={min_x,min_y,0.0};
    cell.bounds.maximum={max_x,max_y,1.0};
    cell.faces.push_back(
        square_z_face(min_x,max_x,min_y,max_y,0.0,normal_z)
    );
    return cell;
}

void test_704_shared_face()
{
    CellData first=face_cell(0,0.0,1.0,0.0,1.0,1.0);
    CellData second=face_cell(1,0.0,1.0,0.0,1.0,-1.0);

    const ValidityResult result=check_adjacency_704(first,second,0.001,0.000001);
    require(result.status==ValidityStatus::Adjacent,
            "704 shared-area face was not classified adjacent");
    require(result.axis==2,"704 shared Z face did not preserve exact adjacency axis");
}

void test_704_edge_only_contact()
{
    CellData first=face_cell(0,0.0,1.0,0.0,1.0,1.0);
    CellData second=face_cell(1,1.0,2.0,0.0,1.0,-1.0);

    const ValidityResult result=check_adjacency_704(first,second,0.001,0.000001);
    require(result.status==ValidityStatus::NotAdjacent,
            "704 edge-only contact must not be classified adjacent");
}

void test_701_no_overlap()
{
    const manifold::Manifold first=
        manifold::Manifold::Cube(manifold::vec3(1.0,1.0,1.0),true);
    const manifold::Manifold second=
        manifold::Manifold::Cube(manifold::vec3(1.0,1.0,1.0),true)
            .Translate(manifold::vec3(2.0,0.0,0.0));

    const ValidityResult result=check_overlap_701(first,second,0.05);
    require(result.status==ValidityStatus::NoOverlap,
            "separated Manifolds must produce 701 NoOverlap");
}

void test_701_thin_overlap()
{
    const manifold::Manifold first=
        manifold::Manifold::Cube(manifold::vec3(1.0,1.0,1.0),true);
    const manifold::Manifold second=
        manifold::Manifold::Cube(manifold::vec3(1.0,1.0,1.0),true)
            .Translate(manifold::vec3(0.99,0.0,0.0));

    const ValidityResult result=check_overlap_701(first,second,0.05);
    require(result.status==ValidityStatus::ThinOverlap,
            "sub-threshold overlap must produce 701 ThinOverlap");
}

void test_701_thick_overlap()
{
    const manifold::Manifold first=
        manifold::Manifold::Cube(manifold::vec3(1.0,1.0,1.0),true);
    const manifold::Manifold second=
        manifold::Manifold::Cube(manifold::vec3(1.0,1.0,1.0),true)
            .Translate(manifold::vec3(0.5,0.0,0.0));

    const ValidityResult result=check_overlap_701(first,second,0.05);
    require(result.status==ValidityStatus::Overlap,
            "clear positive-volume overlap must produce 701 Overlap");
    require(result.volume>0.0,"701 Overlap must retain positive volume");
    require(!result.vertices.empty() && !result.triangles.empty(),
            "701 Overlap must retain intersection mesh for overlay reuse");
}
} // namespace

int main()
{
    test_704_shared_face();
    test_704_edge_only_contact();
    test_701_no_overlap();
    test_701_thin_overlap();
    test_701_thick_overlap();
    return 0;
}
