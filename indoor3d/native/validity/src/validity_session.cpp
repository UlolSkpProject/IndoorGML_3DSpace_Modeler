#include "validity_session.h"

#include "manifold_adapter.h"
#include "validity_checker.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <stdexcept>
#include <utility>

namespace
{
using namespace IndoorGMLValidityNative;

double elapsed_seconds(std::chrono::steady_clock::time_point started)
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count();
}
} // namespace

namespace IndoorGMLValidityNative
{
ValiditySession::~ValiditySession()
{
    clear();
}

std::size_t ValiditySession::load_batch(const std::uint8_t* data,std::size_t size)
{
    if (running_.load(std::memory_order_acquire))
        throw std::runtime_error("cannot load validity geometry while a check is running");
    join_workers();

    cells_=parse_geometry_batch(data,size);
    requests_.clear();
    results_.clear();
    manifold_cache_.assign(cells_.size(),nullptr);
    manifold_attempted_.assign(cells_.size(),false);
    current_.store(0,std::memory_order_relaxed);
    completed_.store(false,std::memory_order_relaxed);
    return cells_.size();
}

std::size_t ValiditySession::start_check(
    const std::uint8_t* request_data,
    std::size_t request_size,
    double overlap_tolerance,
    double normal_tolerance
)
{
    if (cells_.empty()) throw std::runtime_error("validity geometry is not loaded");
    if (running_.load(std::memory_order_acquire))
        throw std::runtime_error("validity check is already running");
    if (!std::isfinite(overlap_tolerance) || overlap_tolerance <= 0.0)
        throw std::invalid_argument("validity overlap tolerance must be finite and positive");
    if (!std::isfinite(normal_tolerance) || normal_tolerance < 0.0)
        throw std::invalid_argument("validity normal tolerance must be finite and non-negative");

    join_workers();
    requests_=parse_validity_requests(request_data,request_size);
    for (const ValidityPairRequest& request : requests_)
    {
        if (request.first>=cells_.size() || request.second>=cells_.size())
            throw std::invalid_argument("validity request cell index is out of range");
    }

    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        results_.clear();
    }
    overlap_tolerance_=overlap_tolerance;
    normal_tolerance_=normal_tolerance;
    current_.store(0,std::memory_order_relaxed);
    next_work_.store(0,std::memory_order_relaxed);
    cancel_requested_.store(false,std::memory_order_relaxed);
    completed_.store(false,std::memory_order_relaxed);
    overlap_701_count_.store(0,std::memory_order_relaxed);
    adjacency_704_count_.store(0,std::memory_order_relaxed);
    manifold_build_count_.store(0,std::memory_order_relaxed);
    uncertain_count_.store(0,std::memory_order_relaxed);
    duration_.store(0.0,std::memory_order_relaxed);

    if (requests_.empty())
    {
        running_.store(false,std::memory_order_release);
        completed_.store(true,std::memory_order_release);
        return 0;
    }

    const unsigned int hardware=std::max(1u,std::thread::hardware_concurrency());
    const std::size_t worker_count=
        std::min<std::size_t>(requests_.size(),std::min<unsigned int>(hardware,8u));
    active_workers_.store(static_cast<std::uint32_t>(worker_count),std::memory_order_relaxed);
    started_at_=std::chrono::steady_clock::now();
    running_.store(true,std::memory_order_release);
    workers_.reserve(worker_count);
    for (std::size_t index=0; index<worker_count; ++index)
        workers_.emplace_back(&ValiditySession::worker_loop,this);
    return requests_.size();
}

std::shared_ptr<manifold::Manifold> ValiditySession::manifold_for(std::size_t index)
{
    std::lock_guard<std::mutex> lock(cache_mutex_);
    if (manifold_attempted_.at(index)) return manifold_cache_.at(index);
    manifold_attempted_[index]=true;
    manifold_cache_[index]=build_manifold(cells_.at(index));
    if (manifold_cache_[index])
        manifold_build_count_.fetch_add(1,std::memory_order_relaxed);
    return manifold_cache_[index];
}

void ValiditySession::worker_loop()
{
    std::vector<ValidityResult> local;
    while (!cancel_requested_.load(std::memory_order_acquire))
    {
        const std::uint64_t position=next_work_.fetch_add(1,std::memory_order_relaxed);
        if (position>=requests_.size()) break;
        const ValidityPairRequest request=requests_[static_cast<std::size_t>(position)];

        ValidityResult result;
        result.first=request.first;
        result.second=request.second;
        result.code=request.code;

        try
        {
            if (request.code==VALIDITY_CODE_OVERLAP)
            {
                overlap_701_count_.fetch_add(1,std::memory_order_relaxed);
                const auto first=manifold_for(request.first);
                const auto second=manifold_for(request.second);
                if (!first || !second)
                    result.status=ValidityStatus::Uncertain;
                else
                {
                    result=check_overlap_701(*first,*second,overlap_tolerance_);
                    result.first=request.first;
                    result.second=request.second;
                }
            }
            else
            {
                adjacency_704_count_.fetch_add(1,std::memory_order_relaxed);
                result=check_adjacency_704(
                    cells_.at(request.first),
                    cells_.at(request.second),
                    overlap_tolerance_,
                    normal_tolerance_
                );
                result.first=request.first;
                result.second=request.second;
            }
        }
        catch (...)
        {
            result.status=ValidityStatus::Uncertain;
        }

        if (result.status==ValidityStatus::Uncertain)
            uncertain_count_.fetch_add(1,std::memory_order_relaxed);
        local.push_back(std::move(result));
        current_.fetch_add(1,std::memory_order_release);
    }

    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        results_.insert(
            results_.end(),
            std::make_move_iterator(local.begin()),
            std::make_move_iterator(local.end())
        );
    }

    if (active_workers_.fetch_sub(1,std::memory_order_acq_rel)==1)
    {
        duration_.store(elapsed_seconds(started_at_),std::memory_order_release);
        running_.store(false,std::memory_order_release);
        completed_.store(true,std::memory_order_release);
    }
}

ProgressSnapshot ValiditySession::get_progress() const
{
    ProgressSnapshot result;
    result.current=current_.load(std::memory_order_acquire);
    result.total=requests_.size();
    result.running=running_.load(std::memory_order_acquire);
    result.completed=completed_.load(std::memory_order_acquire);
    return result;
}

MetricsSnapshot ValiditySession::get_metrics() const
{
    MetricsSnapshot result;
    result.request_count=requests_.size();
    result.overlap_701_count=overlap_701_count_.load(std::memory_order_acquire);
    result.adjacency_704_count=adjacency_704_count_.load(std::memory_order_acquire);
    result.manifold_build_count=manifold_build_count_.load(std::memory_order_acquire);
    result.uncertain_count=uncertain_count_.load(std::memory_order_acquire);
    result.duration=duration_.load(std::memory_order_acquire);
    return result;
}

std::vector<std::uint8_t> ValiditySession::get_result_bytes()
{
    if (running_.load(std::memory_order_acquire))
        throw std::runtime_error("validity check is still running");
    if (!completed_.load(std::memory_order_acquire))
        throw std::runtime_error("validity result requested before check completed");
    join_workers();
    std::vector<ValidityResult> copy;
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        copy=results_;
    }
    return serialize_validity_results(std::move(copy));
}

void ValiditySession::clear()
{
    cancel_requested_.store(true,std::memory_order_release);
    join_workers();
    cells_.clear();
    requests_.clear();
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        results_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(cache_mutex_);
        manifold_cache_.clear();
        manifold_attempted_.clear();
    }
    current_.store(0,std::memory_order_relaxed);
    next_work_.store(0,std::memory_order_relaxed);
    active_workers_.store(0,std::memory_order_relaxed);
    running_.store(false,std::memory_order_relaxed);
    completed_.store(false,std::memory_order_relaxed);
    cancel_requested_.store(false,std::memory_order_relaxed);
}

void ValiditySession::join_workers()
{
    for (std::thread& worker : workers_)
        if (worker.joinable()) worker.join();
    workers_.clear();
}
} // namespace IndoorGMLValidityNative
