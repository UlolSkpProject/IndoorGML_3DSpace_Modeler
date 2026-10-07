#pragma once

#include "validity_data.h"

#include <manifold/manifold.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace IndoorGMLValidityNative
{
struct ProgressSnapshot
{
    std::uint64_t current=0;
    std::uint64_t total=0;
    bool running=false;
    bool completed=false;
};

struct MetricsSnapshot
{
    std::uint64_t request_count=0;
    std::uint64_t overlap_701_count=0;
    std::uint64_t adjacency_704_count=0;
    std::uint64_t manifold_build_count=0;
    std::uint64_t uncertain_count=0;
    double duration=0.0;
};

class ValiditySession
{
public:
    ValiditySession()=default;
    ~ValiditySession();

    std::size_t load_batch(const std::uint8_t* data,std::size_t size);
    std::size_t start_check(
        const std::uint8_t* requests,
        std::size_t request_size,
        double overlap_tolerance,
        double normal_tolerance
    );
    ProgressSnapshot get_progress() const;
    MetricsSnapshot get_metrics() const;
    std::vector<std::uint8_t> get_result_bytes();
    void clear();

private:
    void worker_loop();
    void join_workers();
    std::shared_ptr<manifold::Manifold> manifold_for(std::size_t index);

    std::vector<IndoorGMLAdjacencyNative::CellData> cells_;
    std::vector<ValidityPairRequest> requests_;
    std::vector<ValidityResult> results_;

    std::vector<std::shared_ptr<manifold::Manifold>> manifold_cache_;
    std::vector<bool> manifold_attempted_;

    mutable std::mutex result_mutex_;
    mutable std::mutex cache_mutex_;
    std::vector<std::thread> workers_;

    double overlap_tolerance_=0.0;
    double normal_tolerance_=0.000001;

    std::atomic<std::uint64_t> current_{0};
    std::atomic<std::uint64_t> next_work_{0};
    std::atomic<std::uint32_t> active_workers_{0};
    std::atomic<bool> running_{false};
    std::atomic<bool> completed_{false};
    std::atomic<bool> cancel_requested_{false};

    std::atomic<std::uint64_t> overlap_701_count_{0};
    std::atomic<std::uint64_t> adjacency_704_count_{0};
    std::atomic<std::uint64_t> manifold_build_count_{0};
    std::atomic<std::uint64_t> uncertain_count_{0};
    std::atomic<double> duration_{0.0};
    std::chrono::steady_clock::time_point started_at_{};
};
} // namespace IndoorGMLValidityNative
