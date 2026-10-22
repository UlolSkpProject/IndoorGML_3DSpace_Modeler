#include "floor_polygon_reference.h"
#include <stdexcept>

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

void test_merge_convexity_alone_allows_fifty_millimetre_flatness()
{
    // A 25.4 mm step represents a tessellated, visually straight boundary.
    // It is accepted by the merge-only 50 mm turn tolerance even though the
    // caller's topology tolerance remains 0.001 inch.
    const auto within=merge_convex_partitions({
        {6,1,make_face(rectangle(0,0,10,10))},
        {6,1,make_face(rectangle(10,0,20,9))}
    },0.001);
    check(within.accepted_merges==1 && within.leaves.size()==1,
          "Merge convexity must flatten a sub-50 mm inward boundary step");

    // A 76.2 mm step remains a material concavity and must not be hidden by
    // the merge-only allowance.
    const auto beyond=merge_convex_partitions({
        {6,1,make_face(rectangle(0,0,10,10))},
        {6,1,make_face(rectangle(10,0,20,7))}
    },0.001);
    check(beyond.accepted_merges==0 && beyond.leaves.size()==2,
          "Merge convexity must reject an inward step beyond 50 mm");
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

void test_distinct_coplanar_floor_faces_coarsen_together()
{
    const std::vector<PartitionLeaf> leaves{
        {10,0,make_face(rectangle(0,0,4,4))},
        {11,0,make_face(rectangle(4,0,8,4))},
        {12,0,make_face(rectangle(8,0,12,4))}
    };
    const auto result=merge_convex_partitions(leaves,0.001);
    check(result.accepted_merges==2 && result.leaves.size()==1,
          "Different original SketchUp Faces must merge when coplanar and convex");
    check(near(result.leaves.front().polygon.outer.signed_area,48.0) &&
          result.leaves.front().polygon.outer.points.size()==4,
          "Cross-Face merge must conserve area and form one convex ring");
    check(result.source_leaf_indices.front()==
          std::vector<std::size_t>({0,1,2}),
          "Cross-Face union must retain full original leaf provenance");
    check(result.leaves.front().source_face_id==10,
          "Merged source_face_id should remain a deterministic representative");
    check(leaves[0].source_face_id==10 && leaves[1].source_face_id==11,
          "Original per-Face provenance must not be modified");
}

void test_non_coplanar_floor_faces_stay_separate()
{
    const auto flat=make_face(rectangle(0,0,4,4));
    auto raised=rectangle(4,0,8,4);
    for(Vec3& p:raised)p.z=0.1;
    const auto elevated=make_face(raised);
    const auto different_height=merge_convex_partitions(
        {{10,0,flat},{11,0,elevated}},0.001);
    check(different_height.accepted_merges==0 &&
          different_height.leaves.size()==2,
          "Different parallel floor heights must never be flattened and merged");

    // Both faces are planar individually, but the second slopes about
    // their shared boundary. A pure local-frame round trip misses this.
    const std::vector<Vec3> inclined{
        {4,0,0},{8,0,0},{8,4,0.04},{4,4,0.04}
    };
    const auto prepared=prepare(Vec3{0,-0.01,1},inclined,{},0.001);
    check(bool(prepared.face),"Inclined test polygon must itself be planar");
    const auto tilted=merge_convex_partitions(
        {{10,0,flat},{11,0,*prepared.face}},0.001);
    check(tilted.accepted_merges==0 && tilted.leaves.size()==2,
          "Coplanar merging must reject a tilted neighbouring Face");
}

void test_reversed_coplanar_face_winding_is_normalized()
{
    const auto first=make_face(rectangle(0,0,4,4));
    const auto reversed=prepare(Vec3{0,0,-1},
                                rectangle(4,0,8,4),{},0.001);
    check(bool(reversed.face),"Reversed Floor Face must be individually valid");
    const auto result=merge_convex_partitions(
        {{24,0,first},{25,0,*reversed.face}},0.001);
    check(result.accepted_merges==1 && result.leaves.size()==1 &&
          near(result.leaves.front().polygon.outer.signed_area,32.0),
          "Opposite source winding must not block a genuine coplanar union");
}

void test_cross_face_overlap_and_corner_touch_are_not_shared_edges()
{
    const auto overlapping=merge_convex_partitions({
        {20,0,make_face(rectangle(0,0,4,4))},
        {21,0,make_face(rectangle(3,0,8,4))}
    },0.001);
    check(overlapping.accepted_merges==0,
          "Overlapping Floor material must not be merged as shared boundary");

    const auto corner_only=merge_convex_partitions({
        {22,0,make_face(rectangle(0,0,4,4))},
        {23,0,make_face(rectangle(4,4,8,8))}
    },0.001);
    check(corner_only.accepted_merges==0,
          "A single touching vertex cannot create a Polygon adjacency edge");
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

void test_rejected_maximum_recovers_safe_partial_polygon()
{
    const std::vector<PartitionLeaf> leaves{
        {18,1,make_face(rectangle(0,0,4,4))},
        {18,1,make_face(rectangle(4,0,8,4))},
        {18,1,make_face(rectangle(8,0,12,4))}
    };
    const auto maximal=merge_convex_partitions(leaves,0.001);
    check(maximal.accepted_merges==2 && maximal.leaves.size()==1,
          "Three aligned rectangles must have a valid convex maximal union");

    std::size_t rejected_full=0;
    const auto result=coarsen_with_safe_fallback(
        leaves,0.001,
        [&](const PartitionLeaf& merged,const std::vector<std::size_t>& ids) {
            check(merged.polygon.holes.empty(),
                  "Safety callback must only receive hole-free merged polygons");
            if(ids.size()>2) { ++rejected_full;return false; }
            return true;
        });
    check(rejected_full>0,
          "The rejected maximal union must trigger incremental recovery");
    check(result.size()==2,
          "Failed three-leaf union must keep a verified two-leaf union");
    double total_area=0.0;
    bool has_pair=false;
    bool has_singleton=false;
    for(const PartitionLeaf& leaf:result)
    {
        const double area=leaf.polygon.outer.signed_area;
        total_area+=area;
        has_pair=has_pair || near(area,32.0);
        has_singleton=has_singleton || near(area,16.0);
    }
    check(has_pair && has_singleton && near(total_area,48.0),
          "Partial fallback must conserve area and every original leaf");
    check(leaves.size()==3 && leaves[0].polygon.outer.points.size()==4,
          "Fallback must leave caller-owned polygons unchanged");
}

void test_safe_maximum_kept_even_if_intermediate_pair_would_fail()
{
    const std::vector<PartitionLeaf> leaves{
        {19,0,make_face(rectangle(0,0,4,4))},
        {19,0,make_face(rectangle(4,0,8,4))},
        {19,0,make_face(rectangle(8,0,12,4))}
    };
    std::size_t checks=0;
    const auto result=coarsen_with_safe_fallback(
        leaves,0.001,
        [&](const PartitionLeaf&,const std::vector<std::size_t>& ids) {
            ++checks;
            return ids.size()==3; // All old safe final merges must survive.
        });
    check(checks==1 && result.size()==1 &&
          near(result.front().polygon.outer.signed_area,48.0),
          "Successful maximal merge must be preserved even if pairs fail");
}

void test_all_failed_safety_preserves_original_order()
{
    const std::vector<PartitionLeaf> leaves{
        {20,1,make_face(rectangle(8,0,12,4))},
        {20,1,make_face(rectangle(0,0,4,4))},
        {20,1,make_face(rectangle(4,0,8,4))}
    };
    const auto result=coarsen_with_safe_fallback(
        leaves,0.001,
        [](const PartitionLeaf&,const std::vector<std::size_t>&) {
            return false;
        });
    check(result.size()==leaves.size(),
          "A rejected group with no safe smaller merge must retain all leaves");
    for(std::size_t i=0;i<leaves.size();++i)
    {
        const auto& original_points=leaves[i].polygon.outer.points;
        const auto& returned_points=result[i].polygon.outer.points;
        check(returned_points.size()==original_points.size(),
              "No accepted merge must preserve each original ring");
        for(std::size_t j=0;j<original_points.size();++j)
            check(near(returned_points[j].x,original_points[j].x) &&
                  near(returned_points[j].y,original_points[j].y),
                  "No accepted merge must preserve original input order");
    }
}

void test_safe_fallback_keeps_separate_successful_maximal_groups()
{
    const std::vector<PartitionLeaf> leaves{
        {21,1,make_face(rectangle(0,0,4,4))},
        {21,1,make_face(rectangle(4,0,8,4))},
        {21,1,make_face(rectangle(8,0,12,4))},
        {21,1,make_face(rectangle(20,0,24,4))},
        {21,1,make_face(rectangle(24,0,28,4))}
    };
    const auto result=coarsen_with_safe_fallback(
        leaves,0.001,
        [](const PartitionLeaf& merged,const std::vector<std::size_t>& ids) {
            return ids.size()<=2 || merged.polygon.outer.signed_area<=32.0;
        });
    check(result.size()==3,
          "Rejected triple may recover a pair while existing distant pair survives");
    double total_area=0.0;
    for(const PartitionLeaf& leaf:result)
        total_area+=leaf.polygon.outer.signed_area;
    check(near(total_area,80.0),
          "Recovery and preexisting successful merges must conserve floor area");
}

void test_safety_callback_exception_fails_closed()
{
    const std::vector<PartitionLeaf> leaves{
        {22,1,make_face(rectangle(0,0,4,4))},
        {22,1,make_face(rectangle(4,0,8,4))}
    };
    const auto result=coarsen_with_safe_fallback(
        leaves,0.001,
        [](const PartitionLeaf&,const std::vector<std::size_t>&) -> bool {
            throw std::runtime_error("simulated Native LOS error");
        });
    check(result.size()==2,
          "Optional coarsening must fail closed without aborting State");
}

void test_geometry_merge_guard_applies_before_pair_commit()
{
    const std::vector<PartitionLeaf> leaves{
        {23,1,make_face(rectangle(0,0,4,4))},
        {23,1,make_face(rectangle(4,0,8,4))},
        {23,1,make_face(rectangle(20,0,24,4))},
        {23,1,make_face(rectangle(24,0,28,4))}
    };
    const auto result=merge_convex_partitions(
        leaves,0.001,
        [](const PartitionLeaf&,const std::vector<std::size_t>& ids) {
            return ids!=std::vector<std::size_t>({0,1});
        });
    check(result.leaves.size()==3 && result.accepted_merges==1,
          "Rejected pair must not prevent other independent safe pair merges");
    check(std::find(result.source_leaf_indices.begin(),
                    result.source_leaf_indices.end(),
                    std::vector<std::size_t>({2,3}))!=
          result.source_leaf_indices.end(),
          "Committed pair must retain its original membership indices");
}

void test_safe_global_reinspection_merges_across_recovered_groups()
{
    // A--B--C form the large horizontal rectangle. D attaches above C,
    // so the full A+B+C+D union is concave and its maximal convex
    // partition is ABC | D. If ABC fails Native verification, the safe
    // AB partial recovery exposes a NEW C--D candidate across groups.
    const std::vector<PartitionLeaf> leaves{
        {40,0,make_face(rectangle(0,0,4,4))},
        {41,0,make_face(rectangle(4,0,8,4))},
        {42,0,make_face(rectangle(8,0,12,4))},
        {43,0,make_face(rectangle(8,4,12,8))}
    };
    const auto maximal=merge_convex_partitions(leaves,0.001);
    check(maximal.leaves.size()==2 &&
          maximal.source_leaf_indices.size()==2,
          "Fixture must form an initial greedy maximal group and neighbour");
    check(std::find(maximal.source_leaf_indices.begin(),
                    maximal.source_leaf_indices.end(),
                    std::vector<std::size_t>({0,1,2}))!=
          maximal.source_leaf_indices.end(),
          "Fixture must first group ABC while leaving D outside");

    bool saw_recovered_across_group=false;
    bool provenance_is_original=true;
    const auto result=coarsen_with_safe_fallback(
        leaves,0.001,
        [&](const PartitionLeaf&,
            const std::vector<std::size_t>& original_indices) {
            provenance_is_original &=
                std::is_sorted(original_indices.begin(),original_indices.end()) &&
                std::all_of(original_indices.begin(),original_indices.end(),
                            [](std::size_t i) { return i<4; });
            if(original_indices==std::vector<std::size_t>({2,3}))
            {
                saw_recovered_across_group=true;
                return true;
            }
            return original_indices.size()<=2;
        });
    check(saw_recovered_across_group && provenance_is_original,
          "Reinspection must revalidate cross-group unions with ORIGINAL IDs");
    check(result.size()==2,
          "Global reinspection must merge C+D after the ABC rollback");
    double area=0;
    for(const auto& leaf:result)
    {
        area+=leaf.polygon.outer.signed_area;
        check(near(leaf.polygon.outer.signed_area,32.0),
              "Result must contain AB and CD, not the rejected ABC");
    }
    check(near(area,64.0),
          "Recovered cross-group partitions must preserve the full floor area");
}

void test_global_reinspection_fails_closed_on_cross_group_los()
{
    const std::vector<PartitionLeaf> leaves{
        {50,0,make_face(rectangle(0,0,4,4))},
        {51,0,make_face(rectangle(4,0,8,4))},
        {52,0,make_face(rectangle(8,0,12,4))},
        {53,0,make_face(rectangle(8,4,12,8))}
    };
    const auto result=coarsen_with_safe_fallback(
        leaves,0.001,
        [](const PartitionLeaf&,const std::vector<std::size_t>& ids) {
            return ids==std::vector<std::size_t>({0,1});
        });
    check(result.size()==3,
          "Blocked Native LOS must retain AB, C and D without unsafe shortcut");
    double area=0.0;
    for(const auto& leaf:result)area+=leaf.polygon.outer.signed_area;
    check(near(area,64.0),
          "Rejected global candidate must not lose or duplicate floor material");
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
    test_merge_convexity_alone_allows_fifty_millimetre_flatness();
    test_mismatched_shared_edge_vertices_still_merge();
    test_distinct_coplanar_floor_faces_coarsen_together();
    test_non_coplanar_floor_faces_stay_separate();
    test_cross_face_overlap_and_corner_touch_are_not_shared_edges();
    test_reversed_coplanar_face_winding_is_normalized();
    test_hole_bearing_leaf_is_never_coarsened();
    test_coarsening_does_not_mutate_input_leaves();
    test_iterative_convex_grid_coarsens_to_one_polygon();
    test_rejected_maximum_recovers_safe_partial_polygon();
    test_safe_maximum_kept_even_if_intermediate_pair_would_fail();
    test_all_failed_safety_preserves_original_order();
    test_safe_fallback_keeps_separate_successful_maximal_groups();
    test_safety_callback_exception_fails_closed();
    test_geometry_merge_guard_applies_before_pair_commit();
    test_safe_global_reinspection_merges_across_recovered_groups();
    test_global_reinspection_fails_closed_on_cross_group_los();
    return 0;
}
