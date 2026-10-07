#include "adjacency_checker.h"

#include <algorithm>
#include <tuple>
#include <utility>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
std::vector<PairIndex> z_sweep_candidates(
    const std::vector<CellData>& cells,
    double tolerance
)
{
    std::vector<std::size_t> order(cells.size());
    for (std::size_t index = 0; index < cells.size(); ++index)
    {
        order[index] = index;
    }
    std::stable_sort(order.begin(), order.end(), [&cells](std::size_t first, std::size_t second) {
        if (cells[first].bounds.minimum.z != cells[second].bounds.minimum.z)
        {
            return cells[first].bounds.minimum.z < cells[second].bounds.minimum.z;
        }
        return first < second;
    });

    std::vector<std::size_t> active;
    std::vector<PairIndex> candidates;
    for (const std::size_t current_index : order)
    {
        const double current_min_z = cells[current_index].bounds.minimum.z;
        active.erase(
            std::remove_if(
                active.begin(),
                active.end(),
                [&](std::size_t other_index) {
                    return cells[other_index].bounds.maximum.z + tolerance < current_min_z;
                }
            ),
            active.end()
        );

        for (const std::size_t other_index : active)
        {
            if (!bounds_overlap(cells[other_index].bounds, cells[current_index].bounds, tolerance))
            {
                continue;
            }
            const std::size_t first = std::min(other_index, current_index);
            const std::size_t second = std::max(other_index, current_index);
            candidates.push_back(PairIndex{first, second});
        }
        active.push_back(current_index);
    }

    std::sort(candidates.begin(), candidates.end(), [](const PairIndex& first, const PairIndex& second) {
        return std::tie(first.first, first.second) < std::tie(second.first, second.second);
    });
    candidates.erase(
        std::unique(candidates.begin(), candidates.end(), [](const PairIndex& first, const PairIndex& second) {
            return first.first == second.first && first.second == second.second;
        }),
        candidates.end()
    );
    return candidates;
}
} // namespace IndoorGMLAdjacencyNative
