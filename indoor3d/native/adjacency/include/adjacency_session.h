#pragma once

#include "adjacency_checker.h"
#include "adjacency_data.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
struct ProgressSnapshot
{
    std::uint64_t current = 0;
    std::uint64_t total = 0;
    bool running = false;
    bool completed = false;
    bool failed = false;
    double candidate_generation_duration = 0.0;
};

struct MetricsSnapshot
{
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
    std::size_t start_check(double length_tolerance, double normal_tolerance);
    ProgressSnapshot get_progress() const;
    std::vector<std::uint8_t> get_result_bytes();
    MetricsSnapshot get_metrics() const;
    void clear();

private:
    void worker_loop();
    void join_workers();
    void record_failure(const std::string& message);

    std::vector<CellData> cells_;
    std::vector<PairIndex> candidates_;
    std::vector<PairResult> results_;
    mutable std::mutex result_mutex_;
    mutable std::mutex error_mutex_;
    std::vector<std::thread> workers_;
    std::string first_error_;

    double length_tolerance_ = 0.001;
    double normal_tolerance_ = 0.000001;

    std::atomic<std::uint64_t> current_{0};
    std::atomic<std::uint64_t> next_pair_{0};
    std::atomic<std::uint32_t> active_workers_{0};
    std::atomic<std::uint64_t> failed_pair_count_{0};
    std::atomic<bool> running_{false};
    std::atomic<bool> completed_{false};
    std::atomic<bool> cancel_requested_{false};
    std::atomic<bool> failed_{false};
    std::atomic<double> candidate_generation_duration_{0.0};
    std::atomic<double> narrow_phase_duration_{0.0};
    std::chrono::steady_clock::time_point narrow_phase_started_at_{};
};
} // namespace IndoorGMLAdjacencyNative
