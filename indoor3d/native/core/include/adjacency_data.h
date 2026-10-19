#pragma once

#include "geometry_data.h"
#include "state_exit_code.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
struct StatePointResult
{
    std::size_t cell_index = 0;
    // A record is emitted for EVERY requested Cell. No State candidate
    // is a normal negative result, not an omitted result or an exception.
    std::optional<Vec3> point;
    StateExitCode exit_code=StateExitCode::LegacyNoState;
    StateDiagnostics diagnostics;
};

std::vector<CellData> parse_input_batch(const std::uint8_t* data, std::size_t size);
std::vector<std::uint8_t> serialize_result_batch(std::vector<PairResult> results);
std::vector<std::uint8_t> serialize_state_result_batch(std::vector<StatePointResult> results);
} // namespace IndoorGMLAdjacencyNative
