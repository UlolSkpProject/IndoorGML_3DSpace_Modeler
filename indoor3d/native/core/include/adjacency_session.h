#pragma once

#include "adjacency_checker.h"
#include "adjacency_data.h"
#include "cell_space_interior_point_locator.h"
#include "reference_graph_pipeline.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
enum class SessionState : std::uint8_t
{
    Empty,
    Ready,
    StateRunning,
    StateComplete,
    AdjacencyRunning,
    AdjacencyComplete
};

enum class ProgressPhase : std::uint8_t
{
    None,
    State,
    Adjacency
};

struct ProgressSnapshot
{
    ProgressPhase phase = ProgressPhase::None;
    std::uint64_t current = 0;
    std::uint64_t total = 0;
    bool running = false;
    bool completed = false;
    bool failed = false;
    double candidate_generation_duration = 0.0;
};

struct MetricsSnapshot
{
    std::uint64_t state_target_count = 0;
    std::uint64_t state_success_count = 0;
    std::uint64_t state_volume_centroid_success_count = 0;
    std::uint64_t state_bvh_count = 0;
    double state_duration = 0.0;
    double state_bvh_build_duration = 0.0;
    double state_bvh_search_duration = 0.0;

    std::uint64_t candidate_count = 0;
    std::uint64_t adjacent_pair_count = 0;
    std::uint64_t failed_pair_count = 0;
    double candidate_generation_duration = 0.0;
    double narrow_phase_duration = 0.0;
};

class AdjacencySession
{
public:
    AdjacencySession() = default;
    ~AdjacencySession();

    AdjacencySession(const AdjacencySession&) = delete;
    AdjacencySession& operator=(const AdjacencySession&) = delete;

    std::size_t load_batch(const std::uint8_t* data, std::size_t size);
    void set_cell_keys(std::vector<std::string> keys);

    std::size_t start_state_check();
    std::vector<std::uint8_t> get_state_result_bytes();
    void commit_reference_graph_batch();
    std::vector<bool> validate_room_los(
        std::size_t cell_index,
        const std::vector<std::pair<Vec3, Vec3>>& segments,
        double tolerance
    ) const;
    std::optional<ReferenceGraphStageSnapshot> get_reference_graph(
        const std::string& cell_key,
        ReferenceGraphStage stage
    ) const;
    std::vector<Vec3> get_reference_transition_curve(
        const std::string& first_cell_key,
        const std::string& second_cell_key,
        const Vec3& waypoint
    ) const;
    std::optional<std::pair<Vec3,Vec3>> get_reference_waypoint_anchors(
        const std::string& first_cell_key,
        const std::string& second_cell_key,
        const Vec3& raw_waypoint
    ) const;
    std::uint64_t get_reference_revision(const std::string& cell_key) const;
    void erase_reference_graphs(const std::vector<std::string>& cell_keys);

    std::size_t start_adjacency_check(double length_tolerance, double normal_tolerance);
    std::vector<std::uint8_t> get_adjacency_result_bytes();

    // V1 Ruby API compatibility aliases.
    std::size_t start_check(double length_tolerance, double normal_tolerance)
    {
        return start_adjacency_check(length_tolerance, normal_tolerance);
    }
    std::vector<std::uint8_t> get_result_bytes()
    {
        return get_adjacency_result_bytes();
    }

    ProgressSnapshot get_progress() const;
    MetricsSnapshot get_metrics() const;
    void clear();

private:
    void state_worker_loop();
    void adjacency_worker_loop();
    void join_workers();
    void record_adjacency_failure(const std::string& message);
    bool has_state_targets() const;

    std::vector<CellData> cells_;
    std::vector<std::string> cell_keys_;
    std::vector<std::size_t> state_targets_;
    std::vector<StatePointResult> state_results_;
    std::vector<PairIndex> candidates_;
    std::vector<PairResult> results_;

    mutable std::mutex result_mutex_;
    struct StoredReferenceGraph
    {
        ReferenceGraphPipeline pipeline;
        std::uint64_t revision = 0;
    };
    mutable std::mutex reference_graph_mutex_;
    std::unordered_map<std::string, StoredReferenceGraph> reference_graphs_;
    std::unordered_map<std::string, ReferenceGraphPipeline> pending_reference_graphs_;
    std::uint64_t next_reference_revision_ = 1;
    bool reference_batch_committed_ = false;
    mutable std::mutex error_mutex_;
    std::vector<std::thread> workers_;
    std::string first_error_;

    double length_tolerance_ = 0.001;
    double normal_tolerance_ = 0.000001;
    double state_tolerance_ = 0.001;

    std::atomic<SessionState> state_{SessionState::Empty};
    std::atomic<ProgressPhase> phase_{ProgressPhase::None};
    std::atomic<std::uint64_t> current_{0};
    std::atomic<std::uint64_t> next_work_{0};
    std::atomic<std::uint32_t> active_workers_{0};
    std::atomic<bool> running_{false};
    std::atomic<bool> completed_{false};
    std::atomic<bool> cancel_requested_{false};
    std::atomic<bool> failed_{false};

    std::atomic<std::uint64_t> failed_pair_count_{0};
    std::atomic<std::uint64_t> state_volume_centroid_success_count_{0};
    std::atomic<std::uint64_t> state_bvh_count_{0};
    std::atomic<double> state_bvh_build_duration_{0.0};
    std::atomic<double> state_bvh_search_duration_{0.0};
    std::atomic<double> state_duration_{0.0};
    std::atomic<double> candidate_generation_duration_{0.0};
    std::atomic<double> narrow_phase_duration_{0.0};

    std::chrono::steady_clock::time_point phase_started_at_{};
};
} // namespace IndoorGMLAdjacencyNative
