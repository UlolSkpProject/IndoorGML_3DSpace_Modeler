#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
constexpr std::uint64_t CELL_FLAG_NEEDS_STATE = 1ull << 0;
constexpr std::uint64_t CELL_FLAG_ADJACENCY_TARGET = 1ull << 1;
constexpr std::uint64_t CELL_FLAG_HAS_FIXED_Z = 1ull << 2;
constexpr std::uint64_t CELL_FLAG_ADJACENCY_DIRTY = 1ull << 3;

struct Vec3
{
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
};

struct Aabb
{
    Vec3 minimum;
    Vec3 maximum;
};

struct Triangle
{
    std::array<Vec3, 3> points;
};

struct Plane
{
    // Ax + By + Cz + D = 0; coefficients are in the SAME world/parent
    // coordinates as the transformed boundary vertices.
    Vec3 normal;
    double d = 0.0;
};

struct FaceData
{
    // Shared immutable-by-convention source geometry. Consumers of
    // partitioning use const FaceData&, never mutate this mesh or loops.
    // Derived from the supplied face plane; not serialized separately.
    // Kept for Exact Adjacency's existing normal comparisons.
    Vec3 normal;
    Plane plane;
    bool has_plane = false; // Geometry inputs without an explicit plane and synthetic fixtures
    std::vector<Vec3> outer_points;
    std::vector<std::vector<Vec3>> inner_loops;
    std::vector<Triangle> triangles;

    // Keep outer_points for existing Exact Adjacency consumers.
    const std::vector<Vec3>& outer_loop() const noexcept { return outer_points; }
    const std::vector<std::vector<Vec3>>& holes() const noexcept { return inner_loops; }
};

enum class CellSpaceCategory : std::uint64_t
{
    Unknown = 0,
    Room = 1,
    Stair = 2,
    Elevator = 3,
    Door = 4,
    Window = 5
};

struct CellData
{
    std::size_t index = 0;
    std::uint64_t flags = CELL_FLAG_ADJACENCY_TARGET;
    Aabb bounds;
    double fixed_z = 0.0;
    std::vector<FaceData> faces;
    CellSpaceCategory category = CellSpaceCategory::Unknown;

    bool needs_state() const { return (flags & CELL_FLAG_NEEDS_STATE) != 0; }
    bool adjacency_target() const { return (flags & CELL_FLAG_ADJACENCY_TARGET) != 0; }
    bool has_fixed_z() const { return (flags & CELL_FLAG_HAS_FIXED_Z) != 0; }
    bool adjacency_dirty() const { return (flags & CELL_FLAG_ADJACENCY_DIRTY) != 0; }
};

struct PairIndex
{
    std::size_t first = 0;
    std::size_t second = 0;
};

struct CandidateResult
{
    std::size_t face1_index = 0;
    std::size_t face2_index = 0;
    int axis = 0;
    double area = 0.0;
    double centroid_x = 0.0;
    double centroid_y = 0.0;
};

struct PairResult
{
    std::size_t cell1_index = 0;
    std::size_t cell2_index = 0;
    int axis = 0;
    std::vector<CandidateResult> candidates;
};

} // namespace IndoorGMLAdjacencyNative
