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
    std::uint64_t reference_status = 0; // temporary legacy diagnostics
    std::vector<Vec3> reference_points;
    std::vector<std::uint64_t> reference_kinds;
    // Auxiliary Room debug graph, serialized only with State-result V5.
    std::vector<Vec3> graph_node_points;
    std::vector<double> graph_node_radii;
    std::vector<std::uint64_t> graph_edge_indices; // pairs: first, second
    struct LoopCandidate
    {
        std::vector<std::uint64_t> vertices;
        Vec3 representative;
        double radius = 0.0;
        std::vector<std::uint64_t> visible_neighbors;
    };
    std::vector<LoopCandidate> graph_loop_candidates;
    struct FloorPartition
    {
        std::vector<Vec3> outer;
        std::vector<std::vector<Vec3>> holes;
    };
    std::vector<FloorPartition> graph_floor_partitions;
};

std::vector<CellData> parse_input_batch(const std::uint8_t* data, std::size_t size);
std::vector<std::uint8_t> serialize_result_batch(std::vector<PairResult> results);
std::vector<std::uint8_t> serialize_state_result_batch(std::vector<StatePointResult> results);
} // namespace IndoorGMLAdjacencyNative
