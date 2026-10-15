#include "floor_polygon_preparation.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>

using namespace IndoorGMLAdjacencyNative;
using namespace IndoorGMLAdjacencyNative::FloorPartition;

namespace
{
void require(bool ok, const char* message)
{
    if (!ok)
    {
        std::cerr << message << '\n';
        std::exit(1);
    }
}

void require(const PreparationResult& r,const char* msg)
{
    require(r.face.has_value(),msg);
}

bool close(double a,double b,double epsilon=1.0e-8)
{
    return std::abs(a-b)<=epsilon;
}

bool close(Vec3 a,Vec3 b,double epsilon=1.0e-8)
{
    return close(a.x,b.x,epsilon) &&
           close(a.y,b.y,epsilon) &&
           close(a.z,b.z,epsilon);
}

std::vector<Vec3> polygon(
    std::initializer_list<Vec3> vertices)
{
    return std::vector<Vec3>(vertices);
}

void test_normalize_loop_winding_start_and_duplicate_closing()
{
    const std::vector<Vec3> outer=polygon({
        {0,6,0},{6,6,0},{6,0,0},{0,0,0},{0,6,0}
    }); // clockwise, explicitly closed
    const std::vector<Vec3> hole=polygon({
        {2,2,0},{4,2,0},{4,4,0},{2,4,0},{2,2,0}
    }); // counterclockwise
    const auto input_outer=outer, input_hole=hole;
    const auto prepared=prepare({0,0,1},outer,{hole},0.001);
    require(prepared && prepared.error==PreparationError::None,
            "Phase 1 should normalize valid outer + hole boundaries");
    const NormalizedFace& face=*prepared.face;
    require(face.outer.signed_area>0 &&
            face.holes.size()==1 &&
            face.holes.front().signed_area<0,
            "Outer must be CCW and each Hole CW in the face-local plane");
    require(face.outer.points.size()==4 && face.holes.front().points.size()==4,
            "Duplicate closing vertex must be removed");
    require(face.outer.source_vertex_indices.size()==face.outer.points.size(),
            "Original vertex identities must survive normalization");
    const auto lex_first=[](const NormalizedLoop& loop) {
        for (const Vec2& p:loop.points)
            if (p.x<loop.points.front().x ||
                (p.x==loop.points.front().x &&
                 p.y<loop.points.front().y))
                return false;
        return true;
    };
    require(lex_first(face.outer)&&lex_first(face.holes.front()),
            "Canonical loop start must be the minimum projected vertex");
    require(outer.size()==input_outer.size() &&
            hole.size()==input_hole.size(),
            "Preparation must not mutate source loops");
    require(close(face.frame.lift(face.outer.points.front()),
                  outer[face.outer.source_vertex_indices.front()]),
            "Loop vertex mappings must refer back to the source");
    const Vec3 inner_world=face.frame.lift(face.holes.front().points.front());
    require(close(inner_world,hole[face.holes.front().source_vertex_indices.front()]),
            "Hole source vertex mapping must survive orientation reversal");
}

void test_inclined_face_and_nonplanar_rejection()
{
    const auto slope=polygon({
        {0,0,0},{4,0,0},{4,4,4},{0,4,4}
    });
    const auto prepared=prepare({0,-1,1},slope,{},0.001);
    require(prepared,"Inclined planar Face should be accepted");
    const NormalizedFace& face=*prepared.face;
    for (std::size_t i=0;i<face.outer.points.size();++i)
    {
        const Vec3 lifted=face.frame.lift(face.outer.points[i]);
        require(close(lifted,slope[face.outer.source_vertex_indices[i]]),
                "Local 2D coordinates must lift onto the original inclined Face");
    }
    auto warped=slope;
    warped[2].z+=0.1;
    const auto rejected=prepare({0,-1,1},warped,{},0.001);
    require(!rejected && rejected.error==PreparationError::NonPlanarLoop,
            "Non-planar Face cannot enter the 2D partition workflow");
    const auto zero_normal=prepare({0,0,0},slope,{},0.001);
    require(!zero_normal && zero_normal.error==PreparationError::InvalidNormal,
            "Invalid Normal should fail before a coordinate frame is used");
}

void test_inner_loop_order_determinism()
{
    const auto outer=polygon({
        {0,0,0},{12,0,0},{12,12,0},{0,12,0}
    });
    const auto left=polygon({
        {1,1,0},{1,3,0},{3,3,0},{3,1,0}
    });
    const auto right=polygon({
        {8,8,0},{8,10,0},{10,10,0},{10,8,0}
    });
    const auto one=prepare({0,0,1},outer,{right,left},0.001);
    const auto two=prepare({0,0,1},outer,{left,right},0.001);
    require(one && two,"Multiple valid Hole boundaries must normalize");
    require(one.face->holes.size()==2 && two.face->holes.size()==2,
            "No Hole may be discarded during normalization");
    for (std::size_t i=0;i<2;++i)
    {
        const Vec2 a=one.face->holes[i].points.front();
        const Vec2 b=two.face->holes[i].points.front();
        require(close(a.x,b.x)&&close(a.y,b.y),
                "Hole processing order must not depend on SketchUp enumeration");
    }
    require(one.face->holes[0].source_loop_index==1 &&
            one.face->holes[1].source_loop_index==2 &&
            two.face->holes[0].source_loop_index==2 &&
            two.face->holes[1].source_loop_index==1,
            "Hole source-loop IDs must be preserved after sorting");
}

void test_outer_reflex_direction_and_threshold()
{
    const auto l=polygon({
        {0,0,0},{3,0,0},{3,1,0},
        {1,1,0},{1,3,0},{0,3,0}
    });
    const auto prepared=prepare({0,0,1},l,{},0.001);
    require(prepared,"L floor preparation failed");
    const auto result=propose_splits(*prepared.face);
    require(result.valid_settings && result.candidates.size()==1,
            "One L reflex must emit exactly one 30-degree split candidate");
    const auto& p=result.candidates.front();
    const Vec3 world=prepared.face->frame.lift(p.origin);
    const Frame& frame=prepared.face->frame;
    const Vec3 direction{
        frame.u.x*p.primary_direction.x+frame.v.x*p.primary_direction.y,
        frame.u.y*p.primary_direction.x+frame.v.y*p.primary_direction.y,
        frame.u.z*p.primary_direction.x+frame.v.z*p.primary_direction.y
    };
    require(p.kind==LoopKind::Outer && !p.bidirectional &&
            close(world,Vec3{1,1,0}) &&
            p.signed_turn_degrees<-30,
            "Outer split start must be the L reflex vertex");
    require(direction.x<0 && direction.y<0,
            "Outer reflex bisector must point into the REAL polygon interior");

    const auto weak=polygon({
        {0,0,0},{4,0,0},{4,4,0},{2,3.8,0},{0,4,0}
    });
    const auto strong=polygon({
        {0,0,0},{4,0,0},{4,4,0},{2,3.2,0},{0,4,0}
    });
    const auto weak_face=prepare({0,0,1},weak,{},0.001);
    const auto strong_face=prepare({0,0,1},strong,{},0.001);
    require(weak_face && strong_face,"Notched floors should normalize");
    require(propose_splits(*weak_face.face).candidates.empty(),
            "A single notch below 30 degrees should not split");
    require(!propose_splits(*strong_face.face).candidates.empty(),
            "A single notch exceeding 30 degrees should yield a candidate");
}

void test_downward_floor_normal_preserves_reflex_direction()
{
    // Actual Room/Stair Floors commonly have outward -Z normals.
    // Reflected 2D winding must still put the bisector INSIDE the L.
    const auto outline=polygon({
        {0,0,0},{3,0,0},{3,1,0},
        {1,1,0},{1,3,0},{0,3,0}
    });
    const auto face=prepare({0,0,-1},outline,{},0.001);
    require(face,"Downward-facing Floor should normalize");
    require(face.face->outer.signed_area>0.0,
            "Outer winding must normalize relative to negative Face normal");
    const auto plan=propose_splits(*face.face);
    require(plan.candidates.size()==1,
            "Downward Floor must preserve the one reflex split candidate");
    const auto& candidate=plan.candidates[0];
    const Frame& frame=face.face->frame;
    const Vec3 direction{
        frame.u.x*candidate.primary_direction.x+
            frame.v.x*candidate.primary_direction.y,
        frame.u.y*candidate.primary_direction.x+
            frame.v.y*candidate.primary_direction.y,
        frame.u.z*candidate.primary_direction.x+
            frame.v.z*candidate.primary_direction.y
    };
    require(close(frame.lift(candidate.origin),Vec3{1,1,0}) &&
            direction.x<0 && direction.y<0,
            "Bisector must point into L interior for both Face normal signs");
}

void test_accumulated_small_reflex_turns()
{
    const auto ring=polygon({
        {0,0,0},{10,0,0},{10,5,0},{8,4.1,0},
        {6,4,0},{4,4.3,0},{2,5,0},{0,5,0}
    });
    const auto prepared=prepare({0,0,1},ring,{},0.001);
    require(prepared,"Smooth concave Floor should normalize");
    const auto candidates=propose_splits(*prepared.face);
    bool accumulated=false;
    for (const auto& item:candidates.candidates)
        if (item.kind==LoopKind::Outer &&
            item.signed_turn_degrees<0.0 &&
            item.signed_turn_degrees>-30.0)
            accumulated=true;
    require(accumulated,
            "Several small negative turns must accumulate to a 30-degree split");
}

void test_hole_candidates_and_first_vertex_fallback()
{
    const auto outer=polygon({
        {0,0,0},{8,0,0},{8,8,0},{0,8,0}
    });
    const auto hole=polygon({
        {3,3,0},{5,3,0},{5,5,0},{3,5,0}
    });
    const auto prepared=prepare({0,0,1},outer,{hole},0.001);
    require(prepared,"Rectangle with one Hole must normalize");
    const auto normal=propose_splits(*prepared.face,30.0);
    require(normal.valid_settings && normal.candidates.size()==4,
            "Inner ring must accumulate its own -90-degree turns");
    for (const auto& candidate:normal.candidates)
        require(candidate.kind==LoopKind::Inner &&
                candidate.bidirectional && !candidate.hole_fallback &&
                candidate.source_loop_index==1,
                "Hole threshold candidates must be bidirectional and ring-local");

    // Larger than a complete CW ring's -360 degree turn: the second
    // traversal MUST NOT accumulate fictional negative turns.
    const auto fallback=propose_splits(*prepared.face,400.0);
    require(fallback.candidates.size()==1,
            "No threshold crossing should use one canonical Hole first point");
    require(fallback.candidates.front().hole_fallback &&
            fallback.candidates.front().vertex_index==0,
            "Hole fallback must start at normalized Inner Loop first vertex");
    const auto invalid=propose_splits(*prepared.face,0.0);
    require(!invalid.valid_settings && invalid.candidates.empty(),
            "Invalid threshold must not produce rays");
}

void test_input_winding_does_not_change_world_split_origin()
{
    auto l=polygon({
        {0,0,0},{3,0,0},{3,1,0},
        {1,1,0},{1,3,0},{0,3,0}
    });
    const auto first=prepare({0,0,1},l,{},0.001);
    std::reverse(l.begin(),l.end());
    std::rotate(l.begin(),l.begin()+2,l.end());
    const auto reversed=prepare({0,0,1},l,{},0.001);
    require(first && reversed,"Both loop windings must be accepted");
    const auto ca=propose_splits(*first.face);
    const auto cb=propose_splits(*reversed.face);
    require(ca.candidates.size()==cb.candidates.size() &&
            ca.candidates.size()==1,
            "Candidate count must not depend on original Loop winding");
    require(close(first.face->frame.lift(ca.candidates[0].origin),
                  reversed.face->frame.lift(cb.candidates[0].origin)),
            "Split start must remain invariant after reversing and rotating a Loop");
}
} // namespace

int main()
{
    test_normalize_loop_winding_start_and_duplicate_closing();
    test_inclined_face_and_nonplanar_rejection();
    test_inner_loop_order_determinism();
    test_outer_reflex_direction_and_threshold();
    test_downward_floor_normal_preserves_reflex_direction();
    test_accumulated_small_reflex_turns();
    test_hole_candidates_and_first_vertex_fallback();
    test_input_winding_does_not_change_world_split_origin();
    return 0;
}
