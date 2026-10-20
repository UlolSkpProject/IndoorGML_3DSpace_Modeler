#include "cell_space_interior_point_locator.h"
#include "floor_face_solid.h"
#include "floor_polygon_reference.h"
#include "floor_reference_loops.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>
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
constexpr double STANDARD_MIN_REFERENCE_RADIUS=150.0/25.4;
constexpr double THIN_CELL_MIN_REFERENCE_RADIUS=30.0/25.4;
constexpr double STANDARD_REFERENCE_HEIGHT=1000.0/25.4;
constexpr double SHORT_CELL_MAX_AABB_HEIGHT=1100.0/25.4;

struct ReferencePolicy
{
    double minimum_radius=STANDARD_MIN_REFERENCE_RADIUS;
    double fixed_height=STANDARD_REFERENCE_HEIGHT;
    bool use_half_first_ceiling_height=false;
};

std::optional<ReferencePolicy> reference_policy(CellSpaceCategory category)
{
    switch (category)
    {
    case CellSpaceCategory::Room:
    case CellSpaceCategory::Stair:
    case CellSpaceCategory::Elevator:
        return ReferencePolicy{};
    case CellSpaceCategory::Door:
        return ReferencePolicy{THIN_CELL_MIN_REFERENCE_RADIUS,
                               STANDARD_REFERENCE_HEIGHT,false};
    case CellSpaceCategory::Window:
        return ReferencePolicy{THIN_CELL_MIN_REFERENCE_RADIUS,0.0,true};
    default:
        return std::nullopt;
    }
}

ReferenceSeeds positioned_seeds(
    const std::vector<PartitionLeaf>& leaves,const CellData& cell,
    const FaceSolid& solid,const ReferencePolicy& policy,double tolerance,
    std::size_t maximum)
{
    double reference_height=policy.fixed_height;
    const double aabb_height=cell.bounds.maximum.z-cell.bounds.minimum.z;
    // A fixed +1000mm reference lands on the ceiling of a 1000mm Solid.
    // Keep short CellSpaces safely inside by using half their AABB height.
    if (!policy.use_half_first_ceiling_height &&
        std::isfinite(aabb_height) && aabb_height>0.0 &&
        aabb_height<=SHORT_CELL_MAX_AABB_HEIGHT)
    {
        reference_height=aabb_height*0.5;
    }
    ReferenceSeeds seeds=generate_reference_seeds(
        leaves,tolerance,{reference_height,maximum});
    if (!policy.use_half_first_ceiling_height) return seeds;

    const double vertical_span=std::max(
        tolerance*8.0,
        cell.bounds.maximum.z-cell.bounds.minimum.z+tolerance*8.0);
    for (Seed& seed:seeds.points)
    {
        const auto ceiling=solid.first_boundary_hit(
            seed.position,{0.0,0.0,1.0},vertical_span,tolerance);
        if (ceiling) seed.position.z+=*ceiling*0.5;
    }
    return seeds;
}

// These seeds are the ONLY modern BEFORE candidates. State is selected
// from all validated centroids and shared-edge midpoints before reductions.
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

bool viable_reference(const FaceSolid& solid,Vec3 point,
                       double minimum_radius,double tolerance)
{
    if (inspect_reference(solid,point,tolerance)!=ReferenceCheck::Valid)
        return false;
    const double wall_distance=solid.nearest_wall_distance(point);
    // A Solid without wall-classified Faces has no finite wall constraint.
    if (!std::isfinite(wall_distance)) return true;
    const double radius=std::max(0.0,wall_distance-tolerance);
    return radius>=minimum_radius;
}

bool merged_group_is_safe(
    const PartitionLeaf& merged,
    const std::vector<std::size_t>& members,
    const std::vector<PartitionLeaf>& original,
    const CellData& cell,const FaceSolid& solid,
    const ReferencePolicy& policy,double tolerance)
{
    const ReferenceSeeds representative=positioned_seeds(
        {merged},cell,solid,policy,tolerance,1);
    if (representative.points.empty()) return false;
    const Vec3 center=representative.points.front().position;
    if (!viable_reference(
            solid,center,policy.minimum_radius,tolerance)) return false;

    std::vector<PartitionLeaf> replaced;
    replaced.reserve(members.size());
    for (std::size_t index:members)
    {
        if (index>=original.size()) return false;
        replaced.push_back(original[index]);
    }
    const ReferenceSeeds old_seeds=positioned_seeds(
        replaced,cell,solid,policy,tolerance,MAX_FINAL_REFERENCES);
    for (const Seed& seed:old_seeds.points)
    {
        if (!viable_reference(
                solid,seed.position,policy.minimum_radius,tolerance)) continue;
        if (squared(sub(center,seed.position))<=tolerance*tolerance) continue;
        if (!solid.visible(center,seed.position,tolerance)) return false;
    }
    return true;
}

std::vector<PartitionLeaf> safely_coarsen(
    const std::vector<PartitionLeaf>& original,
    const CellData& cell,const FaceSolid& solid,
    const ReferencePolicy& policy,double tolerance)
{
    return coarsen_with_safe_fallback(
        original,tolerance,
        [&](const PartitionLeaf& candidate,
            const std::vector<std::size_t>& members) {
            return merged_group_is_safe(
                candidate,members,original,cell,solid,policy,tolerance);
        });
}
} // namespace

CellSpaceInteriorPointResult locate_reference_before(
    const CellData& cell,double tolerance)
{
    CellSpaceInteriorPointResult result;
    result.exit_code=StateExitCode::InvalidInput;
    if (!std::isfinite(tolerance)||tolerance<=0.0) return result;
    const auto policy=reference_policy(cell.category);
    if (!policy) return result;
    result.reference_status=ReferencePointStatus::Failed;

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
    leaves=safely_coarsen(leaves,cell,solid,*policy,tolerance);

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
    const ReferenceSeeds seed_batch=positioned_seeds(
        leaves,cell,solid,*policy,tolerance,MAX_FINAL_REFERENCES);
    result.diagnostics.rejected_centroids=seed_batch.rejected_centroids;
    if (seed_batch.points.empty())
    {
        if (seed_batch.rejected_centroids>0)
            result.exit_code=StateExitCode::InvalidCentroids;
        return result;
    }
    // Validate every initial seed before choosing State or filtering centroids.
    // Category-specific wall radius uses 150 mm for Room/Stair/Elevator and
    // 30 mm for thin Door/Window cells. Full-Solid containment remains
    // mandatory for every centroid and shared-edge seed.
    struct ValidatedSeed {
        const Seed* seed;
        double radius;
    };
    std::vector<ValidatedSeed> valid_seeds;
    valid_seeds.reserve(seed_batch.points.size());
    result.diagnostics.reference_candidates=seed_batch.points.size();

    for (const Seed& seed:seed_batch.points)
    {
        const ReferenceCheck check=inspect_reference(solid,seed.position,tolerance);
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
        const double wall_distance=solid.nearest_wall_distance(seed.position);
        const double radius=std::isfinite(wall_distance) ?
            std::max(0.0,wall_distance-tolerance) :
            std::numeric_limits<double>::infinity();
        if (std::isfinite(wall_distance) &&
            radius<policy->minimum_radius)
        {
            ++result.diagnostics.rejected_clearance;
            continue;
        }
        valid_seeds.push_back({&seed,radius});
    }

    if (valid_seeds.empty())
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

    // Any validated seed can be State, including a shared-edge midpoint.
    // The deterministic first minimum wins a distance tie.
    const Vec3 aabb_center{
        (cell.bounds.minimum.x+cell.bounds.maximum.x)*0.5,
        (cell.bounds.minimum.y+cell.bounds.maximum.y)*0.5,
        (cell.bounds.minimum.z+cell.bounds.maximum.z)*0.5
    };
    std::size_t state_index=0;
    double state_distance=std::numeric_limits<double>::infinity();
    for (std::size_t i=0;i<valid_seeds.size();++i)
    {
        const double distance=squared(sub(valid_seeds[i].seed->position,aabb_center));
        if (distance<state_distance)
        {
            state_index=i;
            state_distance=distance;
        }
    }

    // A Polygon centroid remains when no VALID shared-edge seed belongs to it.
    // Invalid shared-edge seeds must not suppress their owners' centroids.
    std::vector<bool> has_valid_shared(leaves.size(),false);
    for (const ValidatedSeed& validated:valid_seeds)
    {
        const Seed& seed=*validated.seed;
        if (seed.kind!=SeedKind::SharedEdgeMidpoint) continue;
        if (seed.first_leaf<has_valid_shared.size())
            has_valid_shared[seed.first_leaf]=true;
        if (seed.second_leaf<has_valid_shared.size())
            has_valid_shared[seed.second_leaf]=true;
    }

    const auto append_reference=[&](const ValidatedSeed& validated,bool is_state) {
        const std::size_t index=result.debug_graph.nodes.size();
        result.reference_points.push_back({
            validated.seed->position,ReferencePointKind::Final
        });
        result.debug_graph.nodes.push_back({validated.seed->position,validated.radius});
        if (is_state)
        {
            result.state_point=validated.seed->position;
            result.debug_graph.state_node_index=index;
        }
        ++result.diagnostics.accepted_references;
    };

    // Preserve the original validated-seed order. State is identified by its
    // actual node index, not by a privileged position in the node array.
    for (std::size_t i=0;i<valid_seeds.size();++i)
    {
        const Seed& seed=*valid_seeds[i].seed;
        const bool is_state=i==state_index;
        if (is_state || seed.kind==SeedKind::SharedEdgeMidpoint ||
            (seed.kind==SeedKind::PolygonCentroid &&
             seed.first_leaf<has_valid_shared.size() &&
             !has_valid_shared[seed.first_leaf]))
            append_reference(valid_seeds[i],is_state);
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
