#pragma once
#include "adjacency_data.h"
#include "floor_polygon_preparation.h"

#include <array>
#include <cstddef>
#include <limits>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
// Face-based 3D Solid queries for BEFORE (no Triangle dependency).
// AABB BVH is only a broad phase; precise intersection/distance uses
// read-only Outer/Inner Loops and each face's plane normal.
class FaceSolid
{
public:
    explicit FaceSolid(const CellData& cell,double tolerance);
    bool valid() const noexcept { return valid_; }
    bool inside(Vec3 point,double tolerance) const;
    // Distance to every Solid boundary Face. KEEP for State safety checks.
    double nearest_distance(Vec3 point) const;
    // Radius ONLY: closest wall-like Face (not floor/ceiling). Returns
    // infinity when no such Face exists; a missing wall must not reject State.
    double nearest_wall_distance(Vec3 point) const;
    bool visible(Vec3 first,Vec3 last,double tolerance) const;
    // Face-domain intersection for a planar virtual membrane. No sampling
    // may replace the actual Face/Outer/Inner Loop boundary test.
    bool membrane_clear(const std::vector<std::array<Vec3,3>>& patches,
                        double tolerance) const;
private:
    struct Surface {
        FloorPartition::NormalizedFace face;
        Aabb box;
        bool is_wall=false;
    };
    struct Node {
        Aabb box;
        std::size_t left=0,right=0,begin=0,count=0;
        bool has_wall=false;
        bool leaf() const noexcept { return count!=0; }
    };
    std::vector<Surface> surfaces_;
    std::vector<std::size_t> order_;
    std::vector<Node> nodes_;
    bool valid_=false;
    double tolerance_=0.001;

    std::size_t build(std::size_t begin,std::size_t end);
    double face_distance(const Surface& face,Vec3 point) const;
    void collect_hits(std::size_t node,Vec3 origin,Vec3 direction,
                      double maximum,double tolerance,
                      std::vector<double>& out,bool& ambiguous) const;
    double closest(std::size_t node,Vec3 point,double best,
                   bool walls_only) const;
};
} // namespace IndoorGMLAdjacencyNative
