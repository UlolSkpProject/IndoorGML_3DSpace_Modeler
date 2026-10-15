#include "floor_polygon_reference.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <vector>

using namespace IndoorGMLAdjacencyNative::FloorPartition;
using IndoorGMLAdjacencyNative::Vec3;

namespace
{
void check(bool ok,const char* message)
{
    if (!ok) { std::cerr<<message<<'\n'; std::exit(1); }
}
bool near(double a,double b,double epsilon=1.0e-7)
{
    return std::abs(a-b)<=epsilon;
}
std::vector<Vec3> rectangle(double x0,double y0,double x1,double y1)
{
    return {{x0,y0,0},{x1,y0,0},{x1,y1,0},{x0,y1,0}};
}
NormalizedFace make_face(const std::vector<Vec3>& outer,
                         const std::vector<std::vector<Vec3>>& holes={},
                         double tolerance=0.001)
{
    const auto r=prepare(Vec3{0,0,1},outer,holes,tolerance);
    check(bool(r),"test source Face normalization failed");
    return *r.face;
}
SplitCandidate make_ray(const NormalizedFace& face,Vec3 from,Vec3 towards,
                        bool bidirectional)
{
    SplitCandidate result;
    result.kind=bidirectional?LoopKind::Inner:LoopKind::Outer;
    result.origin=face.frame.project(from);
    const Vec2 to=face.frame.project(towards);
    result.primary_direction={
        to.x-result.origin.x,to.y-result.origin.y
    };
    result.bidirectional=bidirectional;
    return result;
}

void test_outer_vertex_hit_and_partition_conservation()
{
    const auto face=make_face({
        {0,0,0},{3,0,0},{3,1,0},
        {1,1,0},{1,3,0},{0,3,0}
    });
    const auto candidates=propose_splits(face);
    check(candidates.valid_settings && !candidates.candidates.empty(),
          "L polygon needs the reflex split candidate");
    const auto trace=trace_split(face,candidates.candidates.front(),0.001);
    check(bool(trace.trace),"Stage 3 should reach the outer boundary");
    check(std::any_of(trace.trace->intersections.begin(),
                      trace.trace->intersections.end(),
                      [](const BoundaryHit& hit) {
                          return hit.kind==LoopKind::Outer &&
                                 hit.existing_vertex;
                      }),
          "Existing outer Vertex intersection must be reusable");

    const auto graph=build_graph(face,*trace.trace,0.001);
    check(bool(graph.graph)&&graph.graph->cut_edges>=1,
          "Stage 4 should insert real Cut HalfEdges");
    const auto cycles=walk_cycles(*graph.graph,face,0.001);
    check(bool(cycles.walk)&&!cycles.walk->cycles.empty(),
          "Stage 5 should close directed HalfEdge walks");
    const auto regions=reconstruct_regions(*cycles.walk,0.001);
    check(bool(regions.extraction)&&regions.extraction->regions.size()==2,
          "Stage 6 should produce two child Outer Loops");
    const auto valid=validate_partition(face,*cycles.walk,*regions.extraction,0.001);
    check(bool(valid.partition) && near(valid.partition->original_area,5.0),
          "Stage 7 must conserve L polygon area");
    check(valid.partition->shared_cuts.size()>=1,
          "Every newly shared Cut must track two adjacent owners");
}

void test_hole_crossing_reconstructs_without_filling_void()
{
    const auto face=make_face(rectangle(0,0,8,8),
                              {rectangle(3,3,5,5)});
    const auto candidates=propose_splits(face);
    check(!candidates.candidates.empty(),"Hole must create split candidates");
    bool accepted=false;
    for (const SplitCandidate& candidate:candidates.candidates)
    {
        const auto trace=trace_split(face,candidate,0.001);
        if (!trace.trace) continue;
        check(trace.trace->inspected_holes>=1,
              "Hole crossing must perform actual Hole Edge intersections");
        const auto partition=attempt_partition(face,candidate,0.001);
        if (!partition.partition) continue;
        accepted=true;
        check(partition.partition->children.size()==2,
              "Hole-penetrating chord must form two material domains");
        check(near(partition.partition->original_area,60.0),
              "Hole area must be subtracted from the source");
        double total=0;
        for (const PartitionRegion& region:partition.partition->children)
        {
            check(region.holes.empty(),
                  "The traversed Hole should become child Outer boundaries");
            total+=region.net_area;
        }
        check(near(total,60.0),"Hole interior must never be filled");
        break;
    }
    check(accepted,"At least one Hole bisector must yield a valid partition");
}

void test_untraversed_hole_remains_inner_loop()
{
    auto ring=rectangle(0,0,12,12);
    ring.insert(ring.begin()+1,{6,0,0}); // valid existing Outer Vertex
    const auto face=make_face(ring,{rectangle(8,8,10,10)});
    const auto ray=make_ray(face,{6,0,0},{6,12,0},false);
    const auto trace=trace_split(face,ray,0.001);
    check(bool(trace.trace)&&trace.trace->inspected_holes==0,
          "Hole AABB broad phase should exclude unrelated holes");
    const auto result=attempt_partition(face,ray,0.001);
    check(bool(result.partition) && result.partition->children.size()==2,
          "Cut away from Hole must split only the outer domain");
    std::size_t holes=0;
    for (const auto& region:result.partition->children)
        holes+=region.holes.size();
    check(holes==1,"The untouched Hole must remain a child Inner Loop");
    check(near(result.partition->original_area,140.0),
          "The untouched Hole must remain subtracted from the area");
}

void test_multiple_holes_on_single_chord()
{
    const auto face=make_face(rectangle(0,0,12,12),
        {rectangle(2,2,4,4),rectangle(8,8,10,10)});
    const auto ray=make_ray(face,{2,2,0},{12,12,0},true);
    const auto trace=trace_split(face,ray,0.001);
    check(bool(trace.trace) && trace.trace->inspected_holes==2 &&
          trace.trace->material_intervals.size()==3,
          "Two Holes must produce three material-only chord intervals");
    const auto result=attempt_partition(face,ray,0.001);
    check(bool(result.partition)&&result.partition->children.size()==2,
          "Both traversed Holes should be absorbed into two child Outers");
    check(near(result.partition->original_area,136.0),
          "Two separate Hole areas must be conserved");
}

void test_tangent_and_overlapping_edge_do_not_commit()
{
    const auto face=make_face(rectangle(0,0,8,8));
    const auto tangent=make_ray(face,{0,0,0},{0,8,0},false);
    const auto result=attempt_partition(face,tangent,0.001);
    check(!result.partition && result.failed_stage!=AttemptStage::None,
          "Boundary-only Cut must not be committed as a partition");
}

void test_failed_attempt_never_mutates_source()
{
    const auto face=make_face(rectangle(0,0,8,8),
                              {rectangle(3,3,5,5)});
    const auto preserved=face.outer.points;
    const auto preserved_hole=face.holes.front().points;
    const auto invalid=make_ray(face,{0,0,0},{0,-8,0},false);
    const auto attempt=attempt_partition(face,invalid,0.001);
    check(!attempt.partition,"Ray pointing away from Floor must fail");
    check(face.outer.points.size()==preserved.size() &&
          face.holes.front().points.size()==preserved_hole.size(),
          "Failed transaction must preserve all source boundary vertices");
    for (std::size_t i=0;i<preserved.size();++i)
        check(near(face.outer.points[i].x,preserved[i].x) &&
              near(face.outer.points[i].y,preserved[i].y),
              "Failed partition modified Outer Loop coordinates");
    for (std::size_t i=0;i<preserved_hole.size();++i)
        check(near(face.holes.front().points[i].x,preserved_hole[i].x) &&
              near(face.holes.front().points[i].y,preserved_hole[i].y),
              "Failed partition modified Inner Loop coordinates");
}

void test_adjacent_partition_rectangles_merge_to_one_convex_leaf()
{
    const std::vector<PartitionLeaf> leaves{
        {3,2,make_face(rectangle(0,0,4,4))},
        {3,2,make_face(rectangle(4,0,8,4))}
    };
    const auto result=merge_convex_partitions(leaves,0.001);
    check(result.accepted_merges==1 && result.leaves.size()==1,
          "Adjacent completed rectangles must coarsen to one convex leaf");
    check(result.leaves.front().polygon.outer.points.size()==4 &&
          near(result.leaves.front().polygon.outer.signed_area,32.0),
          "Merged rectangle must preserve its canonical outer ring and area");
    check(result.source_leaf_indices.front()==std::vector<std::size_t>({0,1}),
          "Merged leaf must retain the exact input leaf membership");
}

void test_concave_union_is_not_merged()
{
    const std::vector<PartitionLeaf> leaves{
        {5,1,make_face(rectangle(0,0,2,8))},
        {5,1,make_face(rectangle(2,0,8,2))}
    };
    const auto result=merge_convex_partitions(leaves,0.001);
    check(result.accepted_merges==0 && result.leaves.size()==2,
          "An L-shaped concave union must keep both completed leaves");
}

void test_mismatched_shared_edge_vertices_still_merge()
{
    const auto left=make_face({
        {0,0,0},{4,0,0},{4,1,0},{4,3,0},{4,4,0},{0,4,0}
    });
    const auto right=make_face(rectangle(4,0,8,4));
    const auto result=merge_convex_partitions(
        {{7,1,left},{7,1,right}},0.001);
    check(result.accepted_merges==1 && result.leaves.size()==1 &&
          result.leaves.front().polygon.outer.points.size()==4,
          "T-junction fragments on a shared edge must cancel before merging");
}

void test_different_source_faces_are_not_coarsened_together()
{
    const auto result=merge_convex_partitions({
        {10,0,make_face(rectangle(0,0,4,4))},
        {11,0,make_face(rectangle(4,0,8,4))}
    },0.001);
    check(result.accepted_merges==0 && result.leaves.size()==2,
          "Coarsening must preserve original SketchUp Floor face ownership");
}

void test_hole_bearing_leaf_is_never_coarsened()
{
    const auto with_hole=make_face(
        rectangle(0,0,8,8),{rectangle(2,2,3,3)});
    const auto adjacent=make_face(rectangle(8,0,12,8));
    const auto result=merge_convex_partitions({
        {12,0,with_hole},{12,0,adjacent}
    },0.001);
    check(result.accepted_merges==0 && result.leaves.size()==2,
          "A Hole-bearing leaf must never enter convex coarsening");
}

void test_coarsening_does_not_mutate_input_leaves()
{
    const std::vector<PartitionLeaf> leaves{
        {14,1,make_face(rectangle(0,0,4,4))},
        {14,1,make_face(rectangle(4,0,8,4))}
    };
    const auto first=leaves.front().polygon.outer.points;
    const auto second=leaves.back().polygon.outer.points;
    const auto result=merge_convex_partitions(leaves,0.001);
    check(result.accepted_merges==1,
          "Non-destructive fixture must still exercise one merge");
    check(leaves.front().polygon.outer.points.size()==first.size() &&
          leaves.back().polygon.outer.points.size()==second.size(),
          "Coarsening must not resize caller-owned boundary rings");
    for (std::size_t i=0;i<first.size();++i)
        check(near(leaves.front().polygon.outer.points[i].x,first[i].x) &&
              near(leaves.front().polygon.outer.points[i].y,first[i].y),
              "Coarsening modified the first caller-owned leaf");
    for (std::size_t i=0;i<second.size();++i)
        check(near(leaves.back().polygon.outer.points[i].x,second[i].x) &&
              near(leaves.back().polygon.outer.points[i].y,second[i].y),
              "Coarsening modified the second caller-owned leaf");
}

void test_iterative_convex_grid_coarsens_to_one_polygon()
{
    const std::vector<PartitionLeaf> leaves{
        {16,2,make_face(rectangle(0,0,4,4))},
        {16,2,make_face(rectangle(4,0,8,4))},
        {16,2,make_face(rectangle(0,4,4,8))},
        {16,2,make_face(rectangle(4,4,8,8))}
    };
    const auto result=merge_convex_partitions(leaves,0.001);
    check(result.accepted_merges==3 && result.leaves.size()==1,
          "A 2x2 artificial partition grid must reach one convex polygon");
    check(result.leaves.front().polygon.outer.points.size()==4 &&
          near(result.leaves.front().polygon.outer.signed_area,64.0),
          "Iterative coarsening must preserve the full grid area");
    check(result.source_leaf_indices.front()==
              std::vector<std::size_t>({0,1,2,3}),
          "Iterative coarsening must retain all original leaf memberships");
}
}

int main()
{
    test_outer_vertex_hit_and_partition_conservation();
    test_hole_crossing_reconstructs_without_filling_void();
    test_untraversed_hole_remains_inner_loop();
    test_multiple_holes_on_single_chord();
    test_tangent_and_overlapping_edge_do_not_commit();
    test_failed_attempt_never_mutates_source();
    test_adjacent_partition_rectangles_merge_to_one_convex_leaf();
    test_concave_union_is_not_merged();
    test_mismatched_shared_edge_vertices_still_merge();
    test_different_source_faces_are_not_coarsened_together();
    test_hole_bearing_leaf_is_never_coarsened();
    test_coarsening_does_not_mutate_input_leaves();
    test_iterative_convex_grid_coarsens_to_one_polygon();
    return 0;
}
