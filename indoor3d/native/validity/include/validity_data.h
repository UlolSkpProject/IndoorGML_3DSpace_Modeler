#pragma once

#include "geometry_data.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace IndoorGMLValidityNative
{
using IndoorGMLAdjacencyNative::CellData;
using IndoorGMLAdjacencyNative::Vec3;

constexpr std::uint32_t VALIDITY_CODE_OVERLAP = 701;
constexpr std::uint32_t VALIDITY_CODE_ADJACENCY = 704;

enum class ValidityStatus : std::uint64_t
{
    NoOverlap = 1,
    ThinOverlap = 2,
    Overlap = 3,
    Adjacent = 4,
    NotAdjacent = 5,
    Uncertain = 6
};

struct ValidityPairRequest
{
    std::size_t first = 0;
    std::size_t second = 0;
    std::uint32_t code = 0;
};

struct ValidityResult
{
    std::size_t first = 0;
    std::size_t second = 0;
    std::uint32_t code = 0;
    ValidityStatus status = ValidityStatus::Uncertain;
    int axis = -1;
    double volume = 0.0;
    std::size_t component_count = 0;
    std::vector<Vec3> vertices;
    std::vector<std::array<std::uint64_t, 3>> triangles;
};

std::vector<CellData> parse_geometry_batch(const std::uint8_t* data, std::size_t size);
std::vector<ValidityPairRequest> parse_validity_requests(const std::uint8_t* data, std::size_t size);
std::vector<std::uint8_t> serialize_validity_results(std::vector<ValidityResult> results);
} // namespace IndoorGMLValidityNative
