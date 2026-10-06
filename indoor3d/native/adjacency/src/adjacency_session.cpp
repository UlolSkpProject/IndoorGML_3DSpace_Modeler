#include "adjacency_session.h"

#include <algorithm>
#include <cmath>
#include <exception>
#include <iterator>
#include <stdexcept>
#include <utility>

namespace
{
double elapsed_seconds(std::chrono::steady_clock::time_point started_at)
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - started_at).count();
}
} // namespace

namespace IndoorGMLAdjacencyNative
{
AdjacencySession::~AdjacencySession()
{
    clear();
}

std::size_t AdjacencySession::load_batch(const std::uint8_t* data, std::size_t size)
{
    if (running_.load(std::memory_order_acquire))
    {
        throw std::runtime_error("cannot load adjacency batch while a check is running");
    }
    join_workers();
    cells_ = parse_input_batch(data, size);
    return cells_.size();
}

std::size_t AdjacencySession::start_check(double length_tolerance, double normal_tolerance)
{
    if (running_.load(std::memory_order_acquire))
    {
        throw std::runtime_error("adjacency check is already running");
    }
    if (!std::isfinite(length_tolerance) || length_tolerance < 0.0 ||
        !std::isfinite(normal_tolerance) || normal_tolerance < 0.0)
    {
        throw std::invalid_argument("adjacency tolerances must be finite and non-negative");
    }

    join_workers();
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        results_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(error_mutex_);
        first_error_.clear();
    }

    length_tolerance_ = length_tolerance;
    normal_tolerance_ = normal_tolerance;
    current_.store(0, std::memory_order_relaxed);
    next_pair_.store(0, std::memory_order_relaxed);
    active_workers_.store(0, std::memory_order_relaxed);
    failed_pair_count_.store(0, std::memory_order_relaxed);
    cancel_requested_.store(false, std::memory_order_relaxed);
    failed_.store(false, std::memory_order_relaxed);
    running_.store(false, std::memory_order_relaxed);
    completed_.store(false, std::memory_order_relaxed);
    narrow_phase_duration_.store(0.0, std::memory_order_relaxed);

    const auto candidate_started_at = std::chrono::steady_clock::now();
    candidates_ = z_sweep_candidates(cells_, length_tolerance_);
    candidate_generation_duration_.store(
        elapsed_seconds(candidate_started_at),
        std::memory_order_release
    );

    if (candidates_.empty())
    {
        completed_.store(true, std::memory_order_release);
        return 0;
    }

    const unsigned int hardware_threads = std::max(1u, std::thread::hardware_concurrency());
    const std::size_t worker_count =
        std::min<std::size_t>(candidates_.size(), std::min<unsigned int>(hardware_threads, 8u));
    active_workers_.store(static_cast<std::uint32_t>(worker_count), std::memory_order_relaxed);
    narrow_phase_started_at_ = std::chrono::steady_clock::now();
    running_.store(true, std::memory_order_release);

    workers_.reserve(worker_count);
    for (std::size_t index = 0; index < worker_count; ++index)
    {
        workers_.emplace_back(&AdjacencySession::worker_loop, this);
    }
    return candidates_.size();
}

void AdjacencySession::worker_loop()
{
    std::vector<PairResult> local_results;

    while (!cancel_requested_.load(std::memory_order_acquire))
    {
        const std::uint64_t pair_position = next_pair_.fetch_add(1, std::memory_order_relaxed);
        if (pair_position >= candidates_.size())
        {
            break;
        }

        try
        {
            const PairIndex& pair = candidates_[static_cast<std::size_t>(pair_position)];
            std::optional<PairResult> result = analyze_pair(
                cells_[pair.first],
                cells_[pair.second],
                length_tolerance_,
                normal_tolerance_
            );
            if (result)
            {
                local_results.push_back(std::move(*result));
            }
        }
        catch (const std::exception& error)
        {
            record_failure(error.what());
            cancel_requested_.store(true, std::memory_order_release);
        }
        catch (...)
        {
            record_failure("unknown adjacency narrow-phase failure");
            cancel_requested_.store(true, std::memory_order_release);
        }

        current_.fetch_add(1, std::memory_order_release);
    }

    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        results_.insert(
            results_.end(),
            std::make_move_iterator(local_results.begin()),
            std::make_move_iterator(local_results.end())
        );
    }

    if (active_workers_.fetch_sub(1, std::memory_order_acq_rel) == 1)
    {
        narrow_phase_duration_.store(
            elapsed_seconds(narrow_phase_started_at_),
            std::memory_order_release
        );
        running_.store(false, std::memory_order_release);
        completed_.store(true, std::memory_order_release);
    }
}

ProgressSnapshot AdjacencySession::get_progress() const
{
    ProgressSnapshot snapshot;
    snapshot.current = current_.load(std::memory_order_acquire);
    snapshot.total = static_cast<std::uint64_t>(candidates_.size());
    snapshot.running = running_.load(std::memory_order_acquire);
    snapshot.completed = completed_.load(std::memory_order_acquire);
    snapshot.failed = failed_.load(std::memory_order_acquire);
    snapshot.candidate_generation_duration =
        candidate_generation_duration_.load(std::memory_order_acquire);
    return snapshot;
}

std::vector<std::uint8_t> AdjacencySession::get_result_bytes()
{
    if (running_.load(std::memory_order_acquire))
    {
        throw std::runtime_error("adjacency check is still running");
    }
    join_workers();

    if (failed_.load(std::memory_order_acquire))
    {
        std::lock_guard<std::mutex> lock(error_mutex_);
        throw std::runtime_error(
            first_error_.empty() ? "adjacency native check failed" : first_error_
        );
    }

    std::vector<PairResult> copy;
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        copy = results_;
    }
    return serialize_result_batch(std::move(copy));
}

MetricsSnapshot AdjacencySession::get_metrics() const
{
    MetricsSnapshot snapshot;
    snapshot.candidate_count = static_cast<std::uint64_t>(candidates_.size());
    snapshot.failed_pair_count = failed_pair_count_.load(std::memory_order_acquire);
    snapshot.candidate_generation_duration =
        candidate_generation_duration_.load(std::memory_order_acquire);
    snapshot.narrow_phase_duration =
        narrow_phase_duration_.load(std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        snapshot.adjacent_pair_count = static_cast<std::uint64_t>(results_.size());
    }
    return snapshot;
}

void AdjacencySession::clear()
{
    cancel_requested_.store(true, std::memory_order_release);
    join_workers();

    cells_.clear();
    candidates_.clear();
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        results_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(error_mutex_);
        first_error_.clear();
    }

    current_.store(0, std::memory_order_relaxed);
    next_pair_.store(0, std::memory_order_relaxed);
    active_workers_.store(0, std::memory_order_relaxed);
    failed_pair_count_.store(0, std::memory_order_relaxed);
    running_.store(false, std::memory_order_relaxed);
    completed_.store(false, std::memory_order_relaxed);
    cancel_requested_.store(false, std::memory_order_relaxed);
    failed_.store(false, std::memory_order_relaxed);
    candidate_generation_duration_.store(0.0, std::memory_order_relaxed);
    narrow_phase_duration_.store(0.0, std::memory_order_relaxed);
}

void AdjacencySession::join_workers()
{
    for (std::thread& worker : workers_)
    {
        if (worker.joinable())
        {
            worker.join();
        }
    }
    workers_.clear();
}

void AdjacencySession::record_failure(const std::string& message)
{
    failed_.store(true, std::memory_order_release);
    failed_pair_count_.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(error_mutex_);
    if (first_error_.empty())
    {
        first_error_ = message;
    }
}
} // namespace IndoorGMLAdjacencyNative
