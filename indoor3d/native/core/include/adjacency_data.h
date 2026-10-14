#pragma once

#include "geometry_data.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
struct StatePointResult
{
    std::size_t cell_index = 0;
    Vec3 point;
    std::uint64_t reference_status = 0;
    std::vector<Vec3> reference_points;
    std::vector<std::uint64_t> reference_kinds;
    // Auxiliary Room debug graph, serialized only with State-result V5.
    std::vector<Vec3> graph_node_points;
    std::vector<double> graph_node_radii;
    std::vector<std::uint64_t> graph_edge_indices; // pairs: first, second
    struct LoopCandidate
    {
        std::array<std::uint64_t, 3> triangle{};
        Vec3 representative;
        double radius = 0.0;
        std::vector<std::uint64_t> visible_neighbors;
    };
    std::vector<LoopCandidate> graph_loop_candidates;
};

std::vector<CellData> parse_input_batch(const std::uint8_t* data, std::size_t size);
std::vector<std::uint8_t> serialize_result_batch(std::vector<PairResult> results);
std::vector<std::uint8_t> serialize_state_result_batch(std::vector<StatePointResult> results);
} // namespace IndoorGMLAdjacencyNative
