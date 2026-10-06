#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
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

struct FaceData
{
    Vec3 normal;
    std::vector<Vec3> outer_points;
    std::vector<Triangle> triangles;
};

struct CellData
{
    std::size_t index = 0;
    Aabb bounds;
    std::vector<FaceData> faces;
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

std::vector<CellData> parse_input_batch(const std::uint8_t* data, std::size_t size);
std::vector<std::uint8_t> serialize_result_batch(std::vector<PairResult> results);
} // namespace IndoorGMLAdjacencyNative
