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

void atomic_add(std::atomic<double>& target, double value)
{
    double expected = target.load(std::memory_order_relaxed);
    while (!target.compare_exchange_weak(
        expected,
        expected + value,
        std::memory_order_release,
        std::memory_order_relaxed
    )) {}
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
    if (state_.load(std::memory_order_acquire) != SessionState::Empty)
    {
        throw std::runtime_error("native geometry session must be cleared before load_batch");
    }

    std::vector<CellData> parsed = parse_input_batch(data, size);
    cells_ = std::move(parsed);
    cell_keys_.clear();
    state_targets_.clear();
    for (std::size_t index=0; index<cells_.size(); ++index)
    {
        if (cells_[index].needs_state()) state_targets_.push_back(index);
    }

    phase_.store(ProgressPhase::None, std::memory_order_relaxed);
    current_.store(0, std::memory_order_relaxed);
    next_work_.store(0, std::memory_order_relaxed);
    running_.store(false, std::memory_order_relaxed);
    completed_.store(false, std::memory_order_relaxed);
    cancel_requested_.store(false, std::memory_order_relaxed);
    failed_.store(false, std::memory_order_relaxed);
    state_.store(SessionState::Ready, std::memory_order_release);
    return cells_.size();
}

void AdjacencySession::set_cell_keys(std::vector<std::string> keys)
{
    if (state_.load(std::memory_order_acquire) != SessionState::Ready)
        throw std::runtime_error("CellSpace keys require a ready native geometry session");
    if (keys.size() != cells_.size())
        throw std::invalid_argument("CellSpace key count does not match native batch");
    std::vector<std::string> sorted=keys;
    std::sort(sorted.begin(), sorted.end());
    if (std::adjacent_find(sorted.begin(), sorted.end()) != sorted.end())
        throw std::invalid_argument("duplicate CellSpace key in native batch");
    cell_keys_ = std::move(keys);
}

bool AdjacencySession::has_state_targets() const
{
    return !state_targets_.empty();
}

std::size_t AdjacencySession::start_state_check()
{
    if (state_.load(std::memory_order_acquire) != SessionState::Ready)
    {
        throw std::runtime_error("state check requires a ready native geometry session");
    }

    join_workers();
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        state_results_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(error_mutex_);
        first_error_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(reference_graph_mutex_);
        pending_reference_graphs_.clear();
        reference_batch_committed_=false;
    }

    phase_.store(ProgressPhase::State, std::memory_order_relaxed);
    current_.store(0, std::memory_order_relaxed);
    next_work_.store(0, std::memory_order_relaxed);
    active_workers_.store(0, std::memory_order_relaxed);
    cancel_requested_.store(false, std::memory_order_relaxed);
    failed_.store(false, std::memory_order_relaxed);
    completed_.store(false, std::memory_order_relaxed);
    state_volume_centroid_success_count_.store(0, std::memory_order_relaxed);
    state_bvh_count_.store(0, std::memory_order_relaxed);
    state_bvh_build_duration_.store(0.0, std::memory_order_relaxed);
    state_bvh_search_duration_.store(0.0, std::memory_order_relaxed);
    state_duration_.store(0.0, std::memory_order_relaxed);
    phase_started_at_ = std::chrono::steady_clock::now();

    if (state_targets_.empty())
    {
        state_.store(SessionState::StateComplete, std::memory_order_release);
        completed_.store(true, std::memory_order_release);
        return 0;
    }

    const unsigned int hardware_threads = std::max(1u, std::thread::hardware_concurrency());
    const std::size_t worker_count =
        std::min<std::size_t>(state_targets_.size(), std::min<unsigned int>(hardware_threads, 8u));
    active_workers_.store(static_cast<std::uint32_t>(worker_count), std::memory_order_relaxed);
    running_.store(true, std::memory_order_release);
    state_.store(SessionState::StateRunning, std::memory_order_release);

    workers_.reserve(worker_count);
    for (std::size_t index=0; index<worker_count; ++index)
    {
        workers_.emplace_back(&AdjacencySession::state_worker_loop, this);
    }
    return state_targets_.size();
}

void AdjacencySession::state_worker_loop()
{
    std::vector<StatePointResult> local_results;

    while (!cancel_requested_.load(std::memory_order_acquire))
    {
        const std::uint64_t position = next_work_.fetch_add(1, std::memory_order_relaxed);
        if (position >= state_targets_.size()) break;

        const std::size_t cell_position = state_targets_[static_cast<std::size_t>(position)];
        try
        {
            const CellData& cell=cells_[cell_position];
            // Every supported category first uses the Floor reference policy:
            // BEFORE -> AFTER -> COLLAPSED -> OPTIMIZED -> LOS_GRAPH -> State tree.
            // Only a per-cell modern failure may fall back to the legacy
            // volumetric State and its complete one-node Reference graph.
            const CellSpaceInteriorPointResult result=
                locate_cell_space_interior_points(cell,state_tolerance_);
            if (result.exit_code==StateExitCode::Success)
            {
                if (cell_position>=cell_keys_.size())
                    throw std::runtime_error("CellSpace keys were not registered before Reference build");
                if (!result.state_point)
                    throw std::runtime_error("Successful State result omitted its point");
                ReferenceGraphPipeline pipeline=
                    !result.used_legacy_fallback ?
                    build_reference_graph_pipeline(
                        cell,result.debug_graph,state_tolerance_
                    ) :
                    build_state_reference_graph_pipeline(*result.state_point,cell,state_tolerance_);
                std::lock_guard<std::mutex> graph_lock(reference_graph_mutex_);
                pending_reference_graphs_[cell_keys_[cell_position]]=std::move(pipeline);
            }
            const StateSearchMetrics& metrics = result.state_metrics;
            // Every requested Cell gets an explicit State/diagnostic record.
            StatePointResult state_result;
            state_result.cell_index = cells_[cell_position].index;
            state_result.point = result.state_point;
            state_result.exit_code = result.exit_code;
            state_result.diagnostics = result.diagnostics;
            if (result.exit_code == StateExitCode::Success)
            {
                // Graph/radius data stays in the persistent Native repository.
                // The State-result protocol intentionally carries no graph.
                if (metrics.volume_centroid_succeeded)
                    state_volume_centroid_success_count_.fetch_add(1, std::memory_order_relaxed);
            }
            local_results.push_back(std::move(state_result));
            if (metrics.used_bvh)
                state_bvh_count_.fetch_add(1, std::memory_order_relaxed);
            atomic_add(state_bvh_build_duration_, metrics.bvh_build_duration);
            atomic_add(state_bvh_search_duration_, metrics.bvh_search_duration);
        }
        catch (const std::exception& error)
        {
            // Native execution failure is distinct from no candidate.
            {
                std::lock_guard<std::mutex> lock(error_mutex_);
                if (first_error_.empty())
                    first_error_ = "State native worker cell " +
                        std::to_string(cells_[cell_position].index) +
                        ": " + error.what();
            }
            failed_.store(true, std::memory_order_release);
            cancel_requested_.store(true, std::memory_order_release);
        }
        catch (...)
        {
            {
                std::lock_guard<std::mutex> lock(error_mutex_);
                if (first_error_.empty())
                    first_error_ = "State native worker cell " +
                        std::to_string(cells_[cell_position].index) +
                        ": unexpected exception";
            }
            failed_.store(true, std::memory_order_release);
            cancel_requested_.store(true, std::memory_order_release);
        }

        current_.fetch_add(1, std::memory_order_release);
    }

    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        state_results_.insert(
            state_results_.end(),
            std::make_move_iterator(local_results.begin()),
            std::make_move_iterator(local_results.end())
        );
    }

    if (active_workers_.fetch_sub(1, std::memory_order_acq_rel) == 1)
    {
        state_duration_.store(elapsed_seconds(phase_started_at_), std::memory_order_release);
        running_.store(false, std::memory_order_release);
        state_.store(SessionState::StateComplete, std::memory_order_release);
        completed_.store(true, std::memory_order_release);
    }
}

void AdjacencySession::commit_reference_graph_batch(
    const std::vector<std::array<double,16>>& root_to_local)
{
    if(state_.load(std::memory_order_acquire)!=SessionState::StateComplete ||
       failed_.load(std::memory_order_acquire))
        throw std::runtime_error("Reference Graph commit requires a successful State batch");
    std::lock_guard<std::mutex> graph_lock(reference_graph_mutex_);
    if(reference_batch_committed_)
        throw std::runtime_error("Reference Graph batch was already committed");
    if(root_to_local.size()!=cell_keys_.size() || cell_keys_.size()!=cells_.size())
        throw std::invalid_argument("Post-State CellSpace frame count mismatch");

    // Finalize into a temporary map first: a bad transform cannot partially
    // replace already-committed graphs from another CellSpace.
    std::unordered_map<std::string,StoredReferenceGraph> staged;
    for(const std::size_t position:state_targets_)
    {
        if(position>=cell_keys_.size()) continue;
        const auto found=pending_reference_graphs_.find(cell_keys_[position]);
        if(found==pending_reference_graphs_.end()) continue;
        ReferenceGraphPipeline pipeline=found->second;
        finalize_reference_graph_local(pipeline,cells_[position],root_to_local[position]);
        staged.emplace(cell_keys_[position],
                       StoredReferenceGraph{std::move(pipeline),0});
    }
    for(const std::size_t position:state_targets_)
        if(position<cell_keys_.size()) reference_graphs_.erase(cell_keys_[position]);
    for(auto& entry:staged)
    {
        entry.second.revision=next_reference_revision_++;
        reference_graphs_[entry.first]=std::move(entry.second);
    }
    pending_reference_graphs_.clear();
    reference_batch_committed_=true;
}

std::optional<ReferenceGraphStageSnapshot> AdjacencySession::get_reference_graph(
    const std::string& cell_key, ReferenceGraphStage stage
) const
{
    std::lock_guard<std::mutex> lock(reference_graph_mutex_);
    const auto found=reference_graphs_.find(cell_key);
    if(found==reference_graphs_.end()) return std::nullopt;
    if(stage==ReferenceGraphStage::ShortPathGraph)
        return reference_short_path_graph(found->second.pipeline);
    return reference_graph_stage(found->second.pipeline,stage);
}

std::pair<std::vector<Vec3>,std::vector<Vec3>>
AdjacencySession::get_reference_transition_curve(
    const std::string& first_cell_key,const std::string& second_cell_key,
    const Vec3& first_local_waypoint,const Vec3& second_local_waypoint
) const
{
    std::lock_guard<std::mutex> lock(reference_graph_mutex_);
    const auto first=reference_graphs_.find(first_cell_key);
    const auto second=reference_graphs_.find(second_cell_key);
    if(first==reference_graphs_.end() || second==reference_graphs_.end()) return {};
    return {
        reference_transition_polyline(first->second.pipeline,first_local_waypoint),
        reference_transition_polyline(second->second.pipeline,second_local_waypoint)
    };
}

std::optional<std::pair<Vec3,Vec3>>
AdjacencySession::get_reference_waypoint_anchors(
    const std::string& first_cell_key,const std::string& second_cell_key,
    const Vec3& first_local_waypoint,const Vec3& second_local_waypoint) const
{
    std::lock_guard<std::mutex> lock(reference_graph_mutex_);
    const auto first=reference_graphs_.find(first_cell_key);
    const auto second=reference_graphs_.find(second_cell_key);
    if(first==reference_graphs_.end() || second==reference_graphs_.end())
        return std::nullopt;
    const auto first_point=closest_reachable_reference_point(
        first->second.pipeline,first_local_waypoint);
    const auto second_point=closest_reachable_reference_point(
        second->second.pipeline,second_local_waypoint);
    if(!first_point || !second_point) return std::nullopt;
    return std::make_pair(*first_point,*second_point);
}

std::uint64_t AdjacencySession::get_reference_revision(const std::string& cell_key) const
{
    std::lock_guard<std::mutex> lock(reference_graph_mutex_);
    const auto found=reference_graphs_.find(cell_key);
    return found==reference_graphs_.end() ? 0 : found->second.revision;
}

void AdjacencySession::erase_reference_graphs(const std::vector<std::string>& cell_keys)
{
    std::lock_guard<std::mutex> lock(reference_graph_mutex_);
    for(const auto& key:cell_keys) reference_graphs_.erase(key);
}

std::vector<bool> AdjacencySession::validate_room_los(
    std::size_t cell_index,
    const std::vector<std::pair<Vec3, Vec3>>& segments,
    double tolerance
) const
{
    const SessionState phase = state_.load(std::memory_order_acquire);
    if (phase != SessionState::StateComplete)
        throw std::runtime_error("Room LOS requires a completed State session");
    if (cell_index >= cells_.size())
        throw std::out_of_range("Room LOS CellSpace index is out of range");
    if (segments.size() > 2048)
        throw std::invalid_argument("Room LOS segment batch is too large");
    return validate_room_reference_segments(cells_[cell_index], segments, tolerance);
}

std::vector<std::uint8_t> AdjacencySession::get_state_result_bytes()
{
    if (state_.load(std::memory_order_acquire) == SessionState::StateRunning)
        throw std::runtime_error("state check is still running");
    if (state_.load(std::memory_order_acquire) != SessionState::StateComplete)
        throw std::runtime_error("state result requested before state check completed");

    join_workers();
    if (failed_.load(std::memory_order_acquire))
    {
        std::lock_guard<std::mutex> lock(error_mutex_);
        throw std::runtime_error(first_error_.empty() ?
            "State native worker failed" : first_error_);
    }
    std::vector<StatePointResult> copy;
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        copy = state_results_;
    }
    return serialize_state_result_batch(std::move(copy));
}

std::size_t AdjacencySession::start_adjacency_check(
    double length_tolerance,
    double normal_tolerance
)
{
    const SessionState current_state = state_.load(std::memory_order_acquire);
    const bool ready_without_state =
        current_state == SessionState::Ready && !has_state_targets();
    if (!ready_without_state && current_state != SessionState::StateComplete)
    {
        throw std::runtime_error("adjacency check requires completed State phase");
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
    phase_.store(ProgressPhase::Adjacency, std::memory_order_relaxed);
    current_.store(0, std::memory_order_relaxed);
    next_work_.store(0, std::memory_order_relaxed);
    active_workers_.store(0, std::memory_order_relaxed);
    failed_pair_count_.store(0, std::memory_order_relaxed);
    cancel_requested_.store(false, std::memory_order_relaxed);
    failed_.store(false, std::memory_order_relaxed);
    running_.store(false, std::memory_order_relaxed);
    completed_.store(false, std::memory_order_relaxed);
    narrow_phase_duration_.store(0.0, std::memory_order_relaxed);

    const auto candidate_started_at = std::chrono::steady_clock::now();
    std::vector<CellData> adjacency_cells;
    adjacency_cells.reserve(cells_.size());
    for (const CellData& cell : cells_)
    {
        if (cell.adjacency_target()) adjacency_cells.push_back(cell);
    }
    const bool incremental =
        std::any_of(adjacency_cells.begin(), adjacency_cells.end(), [](const CellData& cell) {
            return cell.adjacency_dirty();
        });

    const std::vector<PairIndex> sweep_candidates =
        z_sweep_candidates(adjacency_cells, length_tolerance_);

    // Keep the already-validated Z-sweep semantics unchanged. Incremental mode only
    // filters the sweep output before the expensive exact face narrow phase.
    // With no dirty flags this is byte-for-byte the previous full-adjacency behavior.
    std::vector<PairIndex> mapped;
    mapped.reserve(sweep_candidates.size());
    for (const PairIndex& pair : sweep_candidates)
    {
        const CellData& first = adjacency_cells[pair.first];
        const CellData& second = adjacency_cells[pair.second];
        if (incremental && !first.adjacency_dirty() && !second.adjacency_dirty())
            continue;

        mapped.push_back(PairIndex{first.index, second.index});
    }
    candidates_ = std::move(mapped);

    candidate_generation_duration_.store(
        elapsed_seconds(candidate_started_at),
        std::memory_order_release
    );

    if (candidates_.empty())
    {
        state_.store(SessionState::AdjacencyComplete, std::memory_order_release);
        completed_.store(true, std::memory_order_release);
        return 0;
    }

    const unsigned int hardware_threads = std::max(1u, std::thread::hardware_concurrency());
    const std::size_t worker_count =
        std::min<std::size_t>(candidates_.size(), std::min<unsigned int>(hardware_threads, 8u));
    active_workers_.store(static_cast<std::uint32_t>(worker_count), std::memory_order_relaxed);
    phase_started_at_ = std::chrono::steady_clock::now();
    running_.store(true, std::memory_order_release);
    state_.store(SessionState::AdjacencyRunning, std::memory_order_release);

    workers_.reserve(worker_count);
    for (std::size_t index=0; index<worker_count; ++index)
    {
        workers_.emplace_back(&AdjacencySession::adjacency_worker_loop, this);
    }
    return candidates_.size();
}

void AdjacencySession::adjacency_worker_loop()
{
    std::vector<PairResult> local_results;

    while (!cancel_requested_.load(std::memory_order_acquire))
    {
        const std::uint64_t pair_position = next_work_.fetch_add(1, std::memory_order_relaxed);
        if (pair_position >= candidates_.size()) break;

        try
        {
            const PairIndex& pair = candidates_[static_cast<std::size_t>(pair_position)];
            std::optional<PairResult> result = analyze_pair(
                cells_.at(pair.first),
                cells_.at(pair.second),
                length_tolerance_,
                normal_tolerance_
            );
            if (result) local_results.push_back(std::move(*result));
        }
        catch (const std::exception& error)
        {
            record_adjacency_failure(error.what());
            cancel_requested_.store(true, std::memory_order_release);
        }
        catch (...)
        {
            record_adjacency_failure("unknown adjacency narrow-phase failure");
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
        narrow_phase_duration_.store(elapsed_seconds(phase_started_at_), std::memory_order_release);
        running_.store(false, std::memory_order_release);
        state_.store(SessionState::AdjacencyComplete, std::memory_order_release);
        completed_.store(true, std::memory_order_release);
    }
}

std::vector<std::uint8_t> AdjacencySession::get_adjacency_result_bytes()
{
    if (state_.load(std::memory_order_acquire) == SessionState::AdjacencyRunning)
        throw std::runtime_error("adjacency check is still running");
    if (state_.load(std::memory_order_acquire) != SessionState::AdjacencyComplete)
        throw std::runtime_error("adjacency result requested before adjacency check completed");

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

ProgressSnapshot AdjacencySession::get_progress() const
{
    ProgressSnapshot snapshot;
    snapshot.phase = phase_.load(std::memory_order_acquire);
    snapshot.current = current_.load(std::memory_order_acquire);
    if (snapshot.phase == ProgressPhase::State)
        snapshot.total = static_cast<std::uint64_t>(state_targets_.size());
    else if (snapshot.phase == ProgressPhase::Adjacency)
        snapshot.total = static_cast<std::uint64_t>(candidates_.size());
    snapshot.running = running_.load(std::memory_order_acquire);
    snapshot.completed = completed_.load(std::memory_order_acquire);
    snapshot.failed = failed_.load(std::memory_order_acquire);
    snapshot.candidate_generation_duration =
        candidate_generation_duration_.load(std::memory_order_acquire);
    return snapshot;
}

MetricsSnapshot AdjacencySession::get_metrics() const
{
    MetricsSnapshot snapshot;
    snapshot.state_target_count = static_cast<std::uint64_t>(state_targets_.size());
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        snapshot.state_success_count = static_cast<std::uint64_t>(
        std::count_if(state_results_.begin(), state_results_.end(),
            [](const StatePointResult& item) {
                return item.exit_code == StateExitCode::Success;
            })
    );
        snapshot.adjacent_pair_count = static_cast<std::uint64_t>(results_.size());
    }
    snapshot.state_volume_centroid_success_count =
        state_volume_centroid_success_count_.load(std::memory_order_acquire);
    snapshot.state_bvh_count = state_bvh_count_.load(std::memory_order_acquire);
    snapshot.state_duration = state_duration_.load(std::memory_order_acquire);
    snapshot.state_bvh_build_duration =
        state_bvh_build_duration_.load(std::memory_order_acquire);
    snapshot.state_bvh_search_duration =
        state_bvh_search_duration_.load(std::memory_order_acquire);

    snapshot.candidate_count = static_cast<std::uint64_t>(candidates_.size());
    snapshot.failed_pair_count = failed_pair_count_.load(std::memory_order_acquire);
    snapshot.candidate_generation_duration =
        candidate_generation_duration_.load(std::memory_order_acquire);
    snapshot.narrow_phase_duration = narrow_phase_duration_.load(std::memory_order_acquire);
    return snapshot;
}

void AdjacencySession::clear()
{
    cancel_requested_.store(true, std::memory_order_release);
    join_workers();

    cells_.clear();
    cell_keys_.clear();
    state_targets_.clear();
    candidates_.clear();
    {
        std::lock_guard<std::mutex> lock(result_mutex_);
        state_results_.clear();
        results_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(error_mutex_);
        first_error_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(reference_graph_mutex_);
        pending_reference_graphs_.clear();
        reference_batch_committed_=false;
    }

    state_.store(SessionState::Empty, std::memory_order_release);
    phase_.store(ProgressPhase::None, std::memory_order_relaxed);
    current_.store(0, std::memory_order_relaxed);
    next_work_.store(0, std::memory_order_relaxed);
    active_workers_.store(0, std::memory_order_relaxed);
    failed_pair_count_.store(0, std::memory_order_relaxed);
    running_.store(false, std::memory_order_relaxed);
    completed_.store(false, std::memory_order_relaxed);
    cancel_requested_.store(false, std::memory_order_relaxed);
    failed_.store(false, std::memory_order_relaxed);

    state_volume_centroid_success_count_.store(0, std::memory_order_relaxed);
    state_bvh_count_.store(0, std::memory_order_relaxed);
    state_bvh_build_duration_.store(0.0, std::memory_order_relaxed);
    state_bvh_search_duration_.store(0.0, std::memory_order_relaxed);
    state_duration_.store(0.0, std::memory_order_relaxed);
    candidate_generation_duration_.store(0.0, std::memory_order_relaxed);
    narrow_phase_duration_.store(0.0, std::memory_order_relaxed);
}

void AdjacencySession::join_workers()
{
    for (std::thread& worker : workers_)
    {
        if (worker.joinable()) worker.join();
    }
    workers_.clear();
}

void AdjacencySession::record_adjacency_failure(const std::string& message)
{
    failed_.store(true, std::memory_order_release);
    failed_pair_count_.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(error_mutex_);
    if (first_error_.empty()) first_error_ = message;
}
} // namespace IndoorGMLAdjacencyNative
