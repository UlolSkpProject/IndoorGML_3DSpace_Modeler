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
            // Room/Stair: Polygon->Reference->BEFORE. State is deliberately
            // absent until the completed OPTIMIZED graph selects it.
            // Other categories keep their established State strategy
            // until their own Reference policy exists (no regressions).
            const CellSpaceInteriorPointResult result =
                (cell.category==CellSpaceCategory::Room ||
                 cell.category==CellSpaceCategory::Stair) ?
                locate_reference_before(cell,state_tolerance_) :
                locate_cell_space_interior_points(cell,state_tolerance_);
            const StateSearchMetrics& metrics = result.state_metrics;
            // Every requested Cell gets an explicit record. A successful
            // Room/Stair record may contain a graph and no State point.
            StatePointResult state_result;
            state_result.cell_index = cells_[cell_position].index;
            state_result.point = result.state_point;
            state_result.exit_code = result.exit_code;
            state_result.diagnostics = result.diagnostics;
            if (result.exit_code == StateExitCode::Success)
            {
                state_result.reference_status =
                    static_cast<std::uint64_t>(result.reference_status);
                state_result.reference_points.reserve(result.reference_points.size());
                state_result.reference_kinds.reserve(result.reference_points.size());
                for (const ReferencePoint& reference : result.reference_points)
                {
                    state_result.reference_points.push_back(reference.point);
                    state_result.reference_kinds.push_back(
                        static_cast<std::uint64_t>(reference.kind)
                    );
                }
                state_result.graph_node_points.reserve(result.debug_graph.nodes.size());
                state_result.graph_node_radii.reserve(result.debug_graph.nodes.size());
                for (const ReferenceGraphNode& node : result.debug_graph.nodes)
                {
                    state_result.graph_node_points.push_back(node.point);
                    state_result.graph_node_radii.push_back(node.radius);
                }
                state_result.graph_edge_indices.reserve(result.debug_graph.edges.size() * 2);
                for (const ReferenceGraphEdge& edge : result.debug_graph.edges)
                {
                    state_result.graph_edge_indices.push_back(
                        static_cast<std::uint64_t>(edge.first)
                    );
                    state_result.graph_edge_indices.push_back(
                        static_cast<std::uint64_t>(edge.second)
                    );
                }
                state_result.graph_loop_candidates.reserve(
                    result.debug_graph.loop_candidates.size()
                );
                for (const ReferenceLoopCollapseCandidate& candidate :
                     result.debug_graph.loop_candidates)
                {
                    StatePointResult::LoopCandidate record;
                    record.vertices.reserve(candidate.vertices.size());
                    for (std::size_t index : candidate.vertices)
                        record.vertices.push_back(static_cast<std::uint64_t>(index));
                    record.representative = candidate.representative.point;
                    record.radius = candidate.representative.radius;
                    record.visible_neighbors.reserve(candidate.visible_neighbors.size());
                    for (std::size_t index : candidate.visible_neighbors)
                        record.visible_neighbors.push_back(static_cast<std::uint64_t>(index));
                    state_result.graph_loop_candidates.push_back(std::move(record));
                }
                state_result.graph_floor_partitions.reserve(
                    result.debug_graph.floor_partitions.size()
                );
                for (const ReferenceFloorPartition& partition :
                     result.debug_graph.floor_partitions)
                {
                    StatePointResult::FloorPartition record;
                    record.outer = partition.outer;
                    record.holes = partition.holes;
                    state_result.graph_floor_partitions.push_back(std::move(record));
                }
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
