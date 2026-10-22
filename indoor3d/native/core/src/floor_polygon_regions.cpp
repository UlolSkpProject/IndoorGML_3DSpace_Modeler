#include "floor_polygon_regions.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace IndoorGMLAdjacencyNative::FloorPartition
{
namespace
{
RegionLoop boundary_of(const CycleWalk& walk,std::size_t cycle_id)
{
    const BoundaryCycle& cycle=walk.cycles[cycle_id];
    RegionLoop loop;
    loop.cycle_id=cycle_id;
    loop.signed_area=cycle.signed_area;
    loop.halfedge_ids=cycle.halfedge_ids;
    loop.points.reserve(cycle.vertex_ids.size());
    for (std::size_t vertex:cycle.vertex_ids)
        loop.points.push_back(walk.graph.vertices[vertex].position);
    return loop;
}
} // namespace

RegionResult reconstruct_regions(const CycleWalk& walk,double tolerance)
{
    if (!std::isfinite(tolerance)||tolerance<=0.0)
        return {{},RegionError::DegenerateBoundaryCycle};
    RegionExtraction output;
    output.region_of_cycle.assign(walk.cycles.size(),NO_EDGE);
    std::vector<std::size_t> negative;
    for (std::size_t id=0;id<walk.cycles.size();++id)
    {
        const auto& cycle=walk.cycles[id];
        if (!cycle.material_on_left) continue;
        if (!std::isfinite(cycle.signed_area) ||
            std::abs(cycle.signed_area)<=tolerance*tolerance)
            return {{},RegionError::DegenerateBoundaryCycle};

        if (cycle.signed_area>0)
        {
            const std::size_t index=output.regions.size();
            PartitionRegion region;
            region.outer=boundary_of(walk,id);
            region.net_area=cycle.signed_area;
            output.regions.push_back(std::move(region));
            output.region_of_cycle[id]=index;
        }
        else negative.push_back(id);
    }
    if (output.regions.empty()) return {{},RegionError::NoOuterCycle};

    for (std::size_t id:negative)
    {
        const RegionLoop inner=boundary_of(walk,id);
        std::size_t parent=NO_EDGE;
        double parent_area=0.0;
        for (std::size_t i=0;i<output.regions.size();++i)
        {
            const RegionLoop& outer=output.regions[i].outer;
            if (std::abs(outer.signed_area)<=std::abs(inner.signed_area))
                continue;
            // A Hole that shares an edge with a candidate Outer is NOT
            // an enclosed Hole. Such geometry must be reconstructed as
            // part of the Outer cycle by the DCEL walk.
            bool strictly_inside=true;
            for (const Vec2& v:inner.points)
                if (classify_loop(outer.points,v,tolerance)!=Location::Inside)
                {
                    strictly_inside=false;
                    break;
                }
            if (!strictly_inside) continue;
            if (parent==NO_EDGE || outer.signed_area<parent_area)
            {
                parent=i;
                parent_area=outer.signed_area;
            }
        }
        if (parent==NO_EDGE)
            return {{},RegionError::UnownedHole};
        output.regions[parent].holes.push_back(inner);
        output.regions[parent].net_area-=std::abs(inner.signed_area);
        output.region_of_cycle[id]=parent;
    }
    // Invariant: the area of a material region is the area of its
    // positive boundary cycle less its own negative inner cycles.
    return {std::move(output),RegionError::None};
}
} // namespace IndoorGMLAdjacencyNative::FloorPartition
