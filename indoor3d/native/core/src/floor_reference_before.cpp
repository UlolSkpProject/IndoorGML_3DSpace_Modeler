#include "cell_space_interior_point_locator.h"
#include "floor_face_solid.h"
#include "floor_polygon_reference.h"
#include "floor_reference_loops.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
namespace
{
using namespace FloorPartition;
Vec3 sub(Vec3 a,Vec3 b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
double squared(Vec3 a) { return a.x*a.x+a.y*a.y+a.z*a.z; }
double len(Vec3 a) { return std::sqrt(squared(a)); }

constexpr double FLOOR_MIN_NEGATIVE_NORMAL_Z=0.6;
constexpr std::size_t MAX_FINAL_REFERENCES=4096;
constexpr double MIN_REFERENCE_RADIUS=150.0/25.4; // 150 mm in SketchUp inches
constexpr double REFERENCE_HEIGHT=500.0/25.4;

// These seeds are the ONLY Room/Stair BEFORE candidates. State is selected
// from valid Polygon centroids before graph reductions.
// Classify clearance BEFORE calling inside(): inside() intentionally
// rejects boundary-near points and would otherwise hide the cause.
enum class ReferenceCheck { Valid, Outside, Clearance };
ReferenceCheck inspect_reference(const FaceSolid& solid,Vec3 point,double tol)
{
    const double distance=solid.nearest_distance(point);
    if (std::isfinite(distance) && distance<=tol)
        return ReferenceCheck::Clearance;
    if (!std::isfinite(distance) || !solid.inside(point,tol))
        return ReferenceCheck::Outside;
    return ReferenceCheck::Valid;
}

bool viable_reference(const FaceSolid& solid,Vec3 point,double tolerance)
{
    if (inspect_reference(solid,point,tolerance)!=ReferenceCheck::Valid)
        return false;
    const double wall_distance=solid.nearest_wall_distance(point);
    // A Solid without wall-classified Faces has no finite wall constraint.
    if (!std::isfinite(wall_distance)) return true;
    const double radius=std::max(0.0,wall_distance-tolerance);
    return radius>=MIN_REFERENCE_RADIUS;
}

bool merged_group_is_safe(
    const PartitionLeaf& merged,
    const std::vector<std::size_t>& members,
    const std::vector<PartitionLeaf>& original,
    const FaceSolid& solid,double tolerance)
{
    const ReferenceSeeds representative=generate_reference_seeds(
        {merged},tolerance,{REFERENCE_HEIGHT,1});
    if (representative.points.empty()) return false;
    const Vec3 center=representative.points.front().position;
    if (!viable_reference(solid,center,tolerance)) return false;

    std::vector<PartitionLeaf> replaced;
    replaced.reserve(members.size());
    for (std::size_t index:members)
    {
        if (index>=original.size()) return false;
        replaced.push_back(original[index]);
    }
    const ReferenceSeeds old_seeds=generate_reference_seeds(
        replaced,tolerance,{REFERENCE_HEIGHT,MAX_FINAL_REFERENCES});
    for (const Seed& seed:old_seeds.points)
    {
        if (!viable_reference(solid,seed.position,tolerance)) continue;
        if (squared(sub(center,seed.position))<=tolerance*tolerance) continue;
        if (!solid.visible(center,seed.position,tolerance)) return false;
    }
    return true;
}

std::vector<PartitionLeaf> safely_coarsen(
    const std::vector<PartitionLeaf>& original,
    const FaceSolid& solid,double tolerance)
{
    return coarsen_with_safe_fallback(
        original,tolerance,
        [&](const PartitionLeaf& candidate,
            const std::vector<std::size_t>& members) {
            return merged_group_is_safe(
                candidate,members,original,solid,tolerance);
        });
}
} // namespace

CellSpaceInteriorPointResult locate_reference_before(
    const CellData& cell,double tolerance)
{
    CellSpaceInteriorPointResult result;
    result.exit_code=StateExitCode::InvalidInput;
    if (!std::isfinite(tolerance)||tolerance<=0.0) return result;
    if (cell.category!=CellSpaceCategory::Room &&
        cell.category!=CellSpaceCategory::Stair) return result;

    // Diagnose absent/invalid Floor loops BEFORE constructing the
    // Solid BVH, otherwise invalid Floor geometry is misreported as a
    // generic invalid Solid and the exact failure stage is lost.
    result.exit_code=StateExitCode::NoFloorFaces;
    std::vector<PartitionLeaf> leaves;
    bool partition_limit=false;
    // Each original SketchUp face is immutable. A failed child is held
    // in PartitionBatch.failed, never treated as a successful Polygon.
    // The failed Polygon list belongs to this transaction and is not
    // a trigger for global State/Adjacency fallback.
    for (std::size_t i=0;i<cell.faces.size();++i)
    {
        const FaceData& source=cell.faces[i];
        const double normal_length=len(source.normal);
        if (normal_length<=0.0 ||
            source.normal.z> -FLOOR_MIN_NEGATIVE_NORMAL_Z*normal_length)
            continue;
        ++result.diagnostics.floor_faces;
        const auto prepared=source.has_plane ?
            prepare(source.plane,source.outer_loop(),source.holes(),tolerance) :
            prepare(source.normal,source.outer_loop(),source.holes(),tolerance);
        if (!prepared.face) continue;
        ++result.diagnostics.prepared_faces;
        PartitionBatch batch=partition_queue(*prepared.face,i,tolerance);
        result.diagnostics.failed_polygons+=batch.failed.size();
        for (const PartitionFailure& failure:batch.failed)
            partition_limit=partition_limit || failure.limit_exceeded;
        result.diagnostics.completed_polygons+=batch.completed.size();
        for (PartitionLeaf& leaf:batch.completed)
            leaves.push_back(std::move(leaf));
    }
    if (result.diagnostics.floor_faces==0) return result;
    result.exit_code=StateExitCode::FloorPreparationFailed;
    if (result.diagnostics.prepared_faces==0) return result;

    result.exit_code=StateExitCode::InvalidSolidGeometry;
    FaceSolid solid(cell,tolerance);
    if (!solid.valid()) return result;

    result.exit_code=partition_limit ?
        StateExitCode::PartitionLimitReached : StateExitCode::PartitionFailed;
    if (leaves.empty()) return result;

    // Remove artificial partition seams only when the exact union remains a
    // hole-free convex polygon, even across separate coplanar Floor Faces.
    // The merged centroid must remain a viable Native reference and see the
    // original viable seeds. Failed maximal unions retain safe partial merges,
    // then revisit all surviving neighbouring polygons to a fixed point.
    leaves=safely_coarsen(leaves,solid,tolerance);

    result.debug_graph.floor_partitions.reserve(leaves.size());
    for (const PartitionLeaf& leaf:leaves)
    {
        ReferenceFloorPartition partition;
        partition.outer.reserve(leaf.polygon.outer.points.size());
        for (const Vec2& point:leaf.polygon.outer.points)
            partition.outer.push_back(leaf.polygon.frame.lift(point));
        partition.holes.reserve(leaf.polygon.holes.size());
        for (const NormalizedLoop& hole:leaf.polygon.holes)
        {
            std::vector<Vec3> ring;
            ring.reserve(hole.points.size());
            for (const Vec2& point:hole.points)
                ring.push_back(leaf.polygon.frame.lift(point));
            partition.holes.push_back(std::move(ring));
        }
        result.debug_graph.floor_partitions.push_back(std::move(partition));
    }

    result.exit_code=StateExitCode::NoReferenceCandidates;
    const ReferenceSeeds seed_batch=generate_reference_seeds(
        leaves,tolerance,{REFERENCE_HEIGHT,MAX_FINAL_REFERENCES});
    result.diagnostics.rejected_centroids=seed_batch.rejected_centroids;
    if (seed_batch.points.empty())
    {
        if (seed_batch.rejected_centroids>0)
            result.exit_code=StateExitCode::InvalidCentroids;
        return result;
    }
    // Mark polygons that own a real shared boundary. Their centroids are not
    // ordinary references; only the State centroid survives that filtering.
    std::vector<bool> has_adjacent(leaves.size(),false);
    for (const Seed& seed:seed_batch.points)
        if (seed.kind==SeedKind::SharedEdgeMidpoint)
        {
            if (seed.first_leaf<has_adjacent.size())
                has_adjacent[seed.first_leaf]=true;
            if (seed.second_leaf<has_adjacent.size())
                has_adjacent[seed.second_leaf]=true;
        }

    // Select State from Polygon centroids only, before candidate validation.
    // If this exact AABB-nearest centroid later fails Solid/clearance checks,
    // the CellSpace has no State; a farther centroid is not substituted.
    const Vec3 aabb_center{
        (cell.bounds.minimum.x+cell.bounds.maximum.x)*0.5,
        (cell.bounds.minimum.y+cell.bounds.maximum.y)*0.5,
        (cell.bounds.minimum.z+cell.bounds.maximum.z)*0.5
    };
    const Seed* state_seed=nullptr;
    double state_distance=std::numeric_limits<double>::infinity();
    for (const Seed& seed:seed_batch.points)
    {
        if (seed.kind!=SeedKind::PolygonCentroid) continue;
        const double distance=squared(sub(seed.position,aabb_center));
        if (distance<state_distance)
        {
            state_seed=&seed;
            state_distance=distance;
        }
    }
    if (!state_seed) return result;

    std::vector<const Seed*> candidates;
    candidates.reserve(seed_batch.points.size()+1);
    candidates.push_back(state_seed); // State is deterministically node zero.
    for (const Seed& seed:seed_batch.points)
    {
        if (&seed==state_seed) continue;
        if (seed.kind==SeedKind::SharedEdgeMidpoint ||
            (seed.kind==SeedKind::PolygonCentroid &&
             seed.first_leaf<has_adjacent.size() &&
             !has_adjacent[seed.first_leaf]))
            candidates.push_back(&seed);
    }
    result.diagnostics.reference_candidates=candidates.size();

    for (const Seed* seed_record:candidates)
    {
        const Seed& seed=*seed_record;
        bool duplicate=false;
        for (const ReferenceGraphNode& node:result.debug_graph.nodes)
            if (squared(sub(node.point,seed.position))<=tolerance*tolerance)
            {
                duplicate=true;break;
            }
        if (duplicate) continue;
        const ReferenceCheck check=inspect_reference(
            solid,seed.position,tolerance);
        if (check==ReferenceCheck::Outside)
        {
            ++result.diagnostics.rejected_outside;
            if (&seed==state_seed)
            {
                result.exit_code=StateExitCode::OutsideSolid;
                return result;
            }
            continue;
        }
        if (check==ReferenceCheck::Clearance)
        {
            ++result.diagnostics.rejected_clearance;
            if (&seed==state_seed)
            {
                result.exit_code=StateExitCode::InsufficientClearance;
                return result;
            }
            continue;
        }
        // BEFORE circle radii are the distance to WALL Faces only.
        // The +500 mm floor offset and ceiling must not cap them.
        // All-boundary containment/clearance was already verified by
        // inspect_reference() above and remains strictly unchanged.
        const double wall_distance=solid.nearest_wall_distance(seed.position);
        const double radius=std::isfinite(wall_distance) ?
            std::max(0.0,wall_distance-tolerance) :
            std::numeric_limits<double>::infinity();
        // Reject undersized spheres before BEFORE graph construction, so
        // downstream edges and loop certificates can never
        // refer to a candidate whose usable wall radius is below 150 mm.
        if (std::isfinite(wall_distance) &&
            radius<MIN_REFERENCE_RADIUS)
        {
            ++result.diagnostics.rejected_clearance;
            if (&seed==state_seed)
            {
                result.exit_code=StateExitCode::InsufficientClearance;
                return result;
            }
            continue;
        }

        result.reference_points.push_back({
            seed.position,ReferencePointKind::Final
        });
        result.debug_graph.nodes.push_back({seed.position,radius});
        if (&seed==state_seed)
        {
            result.state_point=seed.position;
            result.debug_graph.state_node_index=
                result.debug_graph.nodes.size()-1;
        }
        ++result.diagnostics.accepted_references;
    }
    if (result.debug_graph.nodes.empty())
    {
        const bool outside=result.diagnostics.rejected_outside>0;
        const bool clearance=result.diagnostics.rejected_clearance>0;
        result.exit_code=outside && clearance ?
            StateExitCode::MixedReferenceRejections :
            outside ? StateExitCode::OutsideSolid :
            clearance ? StateExitCode::InsufficientClearance :
            StateExitCode::NoReferenceCandidates;
        return result;
    }
    // A successful CellSpace remains SUCCESS even if some of its Faces,
    // child Polygons or reference candidates failed independently.
    result.exit_code=StateExitCode::Success;
    result.reference_status=ReferencePointStatus::Succeeded;

    const auto& nodes=result.debug_graph.nodes;
    for (std::size_t i=0;i<nodes.size();++i)
        for (std::size_t j=i+1;j<nodes.size();++j)
        {
            const double combined=nodes[i].radius+nodes[j].radius;
            if ((std::isfinite(combined) && combined<=tolerance) ||
                (std::isfinite(combined) &&
                 squared(sub(nodes[i].point,nodes[j].point))>combined*combined))
                continue;
            if (solid.visible(nodes[i].point,nodes[j].point,tolerance))
                result.debug_graph.edges.push_back({i,j});
        }
    // Certificate generation is optional and fail-closed. BEFORE references
    // and Native visibility edges are immutable.
    certify_before_reference_loops(solid,result.debug_graph,tolerance);
    return result;
}
} // namespace IndoorGMLAdjacencyNative
