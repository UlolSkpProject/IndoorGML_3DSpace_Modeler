#pragma once

#include "geometry_data.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
struct StatePointResult
{
    std::size_t cell_index = 0;
    Vec3 point;
};

std::vector<CellData> parse_input_batch(const std::uint8_t* data, std::size_t size);
std::vector<std::uint8_t> serialize_result_batch(std::vector<PairResult> results);
std::vector<std::uint8_t> serialize_state_result_batch(std::vector<StatePointResult> results);
} // namespace IndoorGMLAdjacencyNative
