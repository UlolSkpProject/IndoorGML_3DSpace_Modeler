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
bool usable(const FaceSolid& solid,Vec3 p,double tolerance)
{
    return solid.inside(p,tolerance) &&
           solid.nearest_distance(p)>tolerance;
}
} // namespace

CellSpaceInteriorPointResult locate_reference_before(
    const CellData& cell,double tolerance)
{
    CellSpaceInteriorPointResult result;
    if (!std::isfinite(tolerance)||tolerance<=0.0) return result;
    if (cell.category!=CellSpaceCategory::Room &&
        cell.category!=CellSpaceCategory::Stair) return result;

    FaceSolid solid(cell,tolerance);
    if (!solid.valid()) return result;

    std::vector<PartitionLeaf> leaves;
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
        const auto prepared=prepare(
            source.normal,source.outer_loop(),source.holes(),tolerance);
        if (!prepared.face) continue;
        PartitionBatch batch=partition_queue(*prepared.face,i,tolerance);
        for (PartitionLeaf& leaf:batch.completed)
            leaves.push_back(std::move(leaf));
    }
    if (leaves.empty()) return result;

    const ReferenceSeeds seed_batch=generate_reference_seeds(
        leaves,tolerance,{1000.0/25.4,MAX_FINAL_REFERENCES});
    // Evaluate candidate validity BEFORE State selection. The first
    // available valid seed becomes Node 0 / State, not a duplicate Final.
    for (const Seed& seed:seed_batch.points)
    {
        if (!usable(solid,seed.position,tolerance)) continue;
        bool duplicate=false;
        for (const ReferenceGraphNode& node:result.debug_graph.nodes)
            if (squared(sub(node.point,seed.position))<=tolerance*tolerance)
            {
                duplicate=true;break;
            }
        if (duplicate) continue;
        const double radius=solid.nearest_distance(seed.position)-tolerance;
        if (!std::isfinite(radius)||radius<=0.0) continue;

        if (!result.state_point)
            result.state_point=seed.position;
        else
            result.reference_points.push_back({
                seed.position,ReferencePointKind::Final
            });
        result.debug_graph.nodes.push_back({seed.position,radius});
    }
    if (!result.state_point) return result;
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
