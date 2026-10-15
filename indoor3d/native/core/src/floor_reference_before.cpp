#include "cell_space_interior_point_locator.h"
#include "floor_face_solid.h"
#include "floor_polygon_reference.h"

#include <algorithm>
#include <cmath>
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

// These seeds are the ONLY candidates eligible to become a Room/Stair
// State. No volume centroid / spatial search / Triangle BVH fallback.
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

    result.exit_code=StateExitCode::NoReferenceCandidates;
    const ReferenceSeeds seed_batch=generate_reference_seeds(
        leaves,tolerance,{1000.0/25.4,MAX_FINAL_REFERENCES});
    result.diagnostics.reference_candidates=seed_batch.points.size();
    result.diagnostics.rejected_centroids=seed_batch.rejected_centroids;
    if (seed_batch.points.empty())
    {
        if (seed_batch.rejected_centroids>0)
            result.exit_code=StateExitCode::InvalidCentroids;
        return result;
    }
    // Evaluate candidate validity BEFORE State selection. The first
    // available valid seed becomes Node 0 / State, not a duplicate Final.
    for (const Seed& seed:seed_batch.points)
    {
        const ReferenceCheck check=inspect_reference(
            solid,seed.position,tolerance);
        if (check==ReferenceCheck::Outside)
        {
            ++result.diagnostics.rejected_outside;
            continue;
        }
        if (check==ReferenceCheck::Clearance)
        {
            ++result.diagnostics.rejected_clearance;
            continue;
        }
        bool duplicate=false;
        for (const ReferenceGraphNode& node:result.debug_graph.nodes)
            if (squared(sub(node.point,seed.position))<=tolerance*tolerance)
            {
                duplicate=true;break;
            }
        if (duplicate) continue;
        const double radius=solid.nearest_distance(seed.position)-tolerance;
        if (!std::isfinite(radius)||radius<=0.0)
        {
            ++result.diagnostics.rejected_clearance;
            continue;
        }

        if (!result.state_point)
            result.state_point=seed.position;
        else
            result.reference_points.push_back({
                seed.position,ReferencePointKind::Final
            });
        result.debug_graph.nodes.push_back({seed.position,radius});
        ++result.diagnostics.accepted_references;
    }
    if (!result.state_point)
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
            if (combined<=tolerance ||
                squared(sub(nodes[i].point,nodes[j].point))>combined*combined)
                continue;
            if (solid.visible(nodes[i].point,nodes[j].point,tolerance))
                result.debug_graph.edges.push_back({i,j});
        }
    // No AFTER/COLLAPSED/INTERNAL certificates or loop candidate
    // generation: this is BEFORE only, for both Room and Stair.
    return result;
}
} // namespace IndoorGMLAdjacencyNative
