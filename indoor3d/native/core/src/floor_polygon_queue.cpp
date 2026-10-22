#include "floor_polygon_queue.h"

#include <cmath>
#include <deque>
#include <utility>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
namespace
{
std::vector<Vec3> world_loop(const Frame& frame,const RegionLoop& loop)
{
    std::vector<Vec3> result;
    result.reserve(loop.points.size());
    for (Vec2 p:loop.points) result.push_back(frame.lift(p));
    return result;
}
std::optional<NormalizedFace> normalize_child(
    const NormalizedFace& parent,const PartitionRegion& child,double tolerance)
{
    std::vector<std::vector<Vec3>> holes;
    holes.reserve(child.holes.size());
    for (const RegionLoop& hole:child.holes)
        holes.push_back(world_loop(parent.frame,hole));
    // Preserve the ORIGINAL authoritative plane unchanged during
    // recursive splitting. Never reconstruct D from child vertices.
    const auto result=prepare(parent.plane,
                              world_loop(parent.frame,child.outer),holes,tolerance);
    return result.face;
}
} // namespace

PartitionBatch partition_queue(const NormalizedFace& source,
                               std::size_t source_face_id,
                               double tolerance,QueueLimits limits)
{
    PartitionBatch output;
    if (!std::isfinite(tolerance) || tolerance<=0.0 ||
        limits.max_splits==0 || limits.max_candidates_per_face==0)
    {
        output.failed.push_back({source_face_id,0,source,{},true,false});
        return output;
    }

    std::deque<PartitionLeaf> work;
    work.push_back({source_face_id,0,source});
    while (!work.empty())
    {
        PartitionLeaf item=std::move(work.front());
        work.pop_front();
        const CandidateResult plan=propose_splits(item.polygon);
        if (!plan.valid_settings)
        {
            output.failed.push_back({
                item.source_face_id,item.depth,std::move(item.polygon),
                {},false,true
            });
            continue;
        }
        if (plan.candidates.empty() && item.polygon.holes.empty())
        {
            output.completed.push_back(std::move(item));
            continue;
        }

        PartitionFailure failure;
        failure.source_face_id=item.source_face_id;
        failure.depth=item.depth;
        failure.polygon=item.polygon;

        if (item.depth>=limits.max_depth ||
            output.accepted_splits>=limits.max_splits)
        {
            failure.limit_exceeded=true;
            output.failed.push_back(std::move(failure));
            continue;
        }
        // A Hole without a usable cut is a failed polygon, never a
        // "complete" polygon. Try all existing candidates before failing.
        bool accepted=false;
        std::size_t candidate_count=0;
        for (const SplitCandidate& candidate:plan.candidates)
        {
            if (++candidate_count>limits.max_candidates_per_face)
            {
                failure.limit_exceeded=true;
                break;
            }
            ++output.attempted_splits;
            PartitionAttempt attempt=attempt_partition(
                item.polygon,candidate,tolerance);
            if (!attempt.partition)
            {
                failure.rejected_candidates.push_back(std::move(attempt));
                continue;
            }
            const auto& children=attempt.partition->children;
            if (children.size()<2 ||
                children.size()>limits.max_splits-output.accepted_splits+1)
            {
                failure.limit_exceeded=true;
                break;
            }
            std::vector<PartitionLeaf> descendants;
            descendants.reserve(children.size());
            bool valid=true;
            for (const PartitionRegion& child:children)
            {
                auto normalized=normalize_child(
                    item.polygon,child,tolerance);
                if (!normalized)
                {
                    valid=false;
                    break;
                }
                descendants.push_back({
                    item.source_face_id,item.depth+1,std::move(*normalized)
                });
            }
            if (!valid)
            {
                failure.invalid_child=true;
                continue;
            }
            // Commit atomically after ALL children normalize; rejected
            // attempts never mutate the parent's loops.
            for (PartitionLeaf& next:descendants)
                work.push_back(std::move(next));
            ++output.accepted_splits;
            accepted=true;
            break;
        }
        if (!accepted) output.failed.push_back(std::move(failure));
    }
    return output;
}
} // namespace IndoorGMLAdjacencyNative::FloorPartition
