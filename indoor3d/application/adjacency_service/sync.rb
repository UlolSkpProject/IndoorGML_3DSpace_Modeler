# frozen_string_literal: true

require 'etc'
require 'thread'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class AdjacencyService
        MIN_PARALLEL_PAIRS = 20_000
        PAIR_CHUNK_SIZE = 5_000
        MAX_WORKERS = 4
        attr_reader :last_metrics

        def initialize(registry, transition_builder:, transition_eraser:)
          @registry = registry
          @transition_builder = transition_builder
          @transition_eraser = transition_eraser
          @last_metrics = {}
        end

        def synchronize_for(cell_space)
          return if cell_space.nil? || !cell_space.valid? || !cell_space.duality_state&.valid?

          @registry.cell_spaces.each do |other_cell_space|
            next if other_cell_space.nil? || other_cell_space == cell_space
            next unless other_cell_space.valid? && other_cell_space.duality_state&.valid?

            pair_key = cell_pair_key(cell_space, other_cell_space)
            adjacency_axis = Utils::Geometry.adjacency_axis(cell_space.sketchup_group, other_cell_space.sketchup_group)
            if transition_allowed_for_axis?(adjacency_axis)
              @registry.set_adjacent_pair(pair_key, cell_space, other_cell_space)
              @transition_builder.call(cell_space, other_cell_space)
            else
              @transition_eraser.call(pair_key)
            end
          end
        end

        def synchronize_all(transition_builder: nil, transition_eraser: nil)
          started_at = monotonic_time
          entries = adjacency_snapshot_entries
          if entries.empty?
            @last_metrics = { total_duration: elapsed_since(started_at), pair_comparison_count: 0 }
            return @last_metrics
          end

          pair_results = compute_pair_results(entries, tolerance: Utils::Geometry::ADJACENCY_TOLERANCE)
          apply_pair_results(
            entries,
            pair_results,
            transition_builder: transition_builder || @transition_builder,
            transition_eraser: transition_eraser || @transition_eraser
          )
          @last_metrics = {
            total_duration: elapsed_since(started_at),
            pair_comparison_count: @last_pair_comparison_count.to_i,
            adjacency_detailed_computation: @last_detailed_computation_duration.to_f
          }
        end

        def synchronize_within(cell_spaces, transition_builder: nil, transition_eraser: nil)
          started_at = monotonic_time
          entries = adjacency_snapshot_entries(cell_spaces)
          pair_results = compute_pair_results(entries, tolerance: Utils::Geometry::ADJACENCY_TOLERANCE)
          apply_pair_results(
            entries,
            pair_results,
            transition_builder: transition_builder || @transition_builder,
            transition_eraser: transition_eraser || @transition_eraser,
            stale_pair_keys: pair_keys_within(entries)
          )
          @last_metrics = {
            total_duration: elapsed_since(started_at),
            pair_comparison_count: @last_pair_comparison_count.to_i,
            adjacency_detailed_computation: @last_detailed_computation_duration.to_f
          }
        end

        def erase_for(cell_space)
          return if cell_space.nil?

          pair_keys = if @registry.respond_to?(:adjacent_pair_keys_for_cell) &&
                         @registry.respond_to?(:transition_pair_keys_for_cell)
                        @registry.adjacent_pair_keys_for_cell(cell_space.id) |
                          @registry.transition_pair_keys_for_cell(cell_space.id)
                      else
                        (@registry.adjacent_pair_keys | @registry.transition_pair_keys).select do |pair_key|
                          pair_key.split(':').include?(cell_space.id)
                        end
                      end
          pair_keys.each { |pair_key| @transition_eraser.call(pair_key) }
        end

        def cell_pair_key(cell1, cell2)
          [cell1.id, cell2.id].sort.join(':')
        end

        private

        def adjacency_snapshot_entries(cell_spaces = @registry.cell_spaces)
          Array(cell_spaces).uniq.each_with_object([]) do |cell_space, entries|
            next if cell_space.nil? || !cell_space.valid?
            next unless cell_space.duality_state&.valid?

            snapshot = Utils::Geometry.adjacency_snapshot(cell_space.sketchup_group)
            next unless snapshot

            entries << { cell_space: cell_space, snapshot: snapshot }
          end.freeze
        end

        def compute_pair_results(entries, tolerance:)
          snapshots = entries.map { |entry| entry[:snapshot] }.freeze
          pair_indices = candidate_pair_indices(snapshots, tolerance)
          @last_pair_comparison_count = pair_indices.length
          return [] if pair_indices.empty?

          started_at = monotonic_time
          if pair_indices.length < MIN_PARALLEL_PAIRS
            return compute_pair_chunk(snapshots, pair_indices, tolerance)
          end

          compute_pair_results_in_parallel(snapshots, pair_indices, tolerance)
        ensure
          @last_detailed_computation_duration = elapsed_since(started_at) if started_at
        end

        def candidate_pair_indices(snapshots, tolerance)
          pairs = []
          count = snapshots.length
          (0...count).each do |index1|
            ((index1 + 1)...count).each do |index2|
              next unless candidate_bounds_touch?(
                snapshots[index1][:bounds],
                snapshots[index2][:bounds],
                tolerance
              )

              pairs << [index1, index2]
            end
          end
          pairs.freeze
        end

        def candidate_bounds_touch?(bounds1, bounds2, tolerance)
          candidate_axis_overlap_or_touch?(bounds1[:min][0], bounds1[:max][0], bounds2[:min][0], bounds2[:max][0], tolerance) &&
            candidate_axis_overlap_or_touch?(bounds1[:min][1], bounds1[:max][1], bounds2[:min][1], bounds2[:max][1], tolerance) &&
            candidate_axis_overlap_or_touch?(bounds1[:min][2], bounds1[:max][2], bounds2[:min][2], bounds2[:max][2], tolerance)
        end

        def candidate_axis_overlap_or_touch?(min1, max1, min2, max2, tolerance)
          [min1, min2].max <= [max1, max2].min + tolerance
        end

        def compute_pair_results_in_parallel(snapshots, pair_indices, tolerance)
          chunks = pair_indices.each_slice(PAIR_CHUNK_SIZE).to_a
          queue = Queue.new
          chunks.each { |chunk| queue << chunk }
          workers = [worker_count, chunks.length].min
          threads = workers.times.map do
            Thread.new do
              local_results = []
              loop do
                chunk = queue.pop(true)
                local_results.concat(compute_pair_chunk(snapshots, chunk, tolerance))
              rescue ThreadError
                break
              end
              local_results
            end
          end
          threads.flat_map(&:value)
        end

        def worker_count
          processor_count = Etc.respond_to?(:nprocessors) ? Etc.nprocessors : 2
          [[processor_count.to_i - 1, 1].max, MAX_WORKERS].min
        rescue StandardError
          2
        end

        def compute_pair_chunk(snapshots, pair_indices, tolerance)
          pair_indices.each_with_object([]) do |(index1, index2), results|
            axis = Utils::Geometry.adjacency_axis_from_snapshots(
              snapshots[index1],
              snapshots[index2],
              tolerance: tolerance
            )
            results << [index1, index2, axis] unless axis.nil?
          end
        end

        def apply_pair_results(entries, pair_results, transition_builder:, transition_eraser:, stale_pair_keys: nil)
          next_pairs = {}
          pair_results.each do |index1, index2, adjacency_axis|
            cell1 = entries[index1][:cell_space]
            cell2 = entries[index2][:cell_space]
            next unless transition_allowed_for_axis?(adjacency_axis)

            pair_key = cell_pair_key(cell1, cell2)
            next_pairs[pair_key] = [cell1, cell2]
          end

          stale_keys = stale_pair_keys || self.stale_pair_keys(next_pairs.keys)
          stale_keys.reject { |pair_key| next_pairs.key?(pair_key) }.each do |pair_key|
            transition_eraser.call(pair_key)
          end
          next_pairs.each do |pair_key, (cell1, cell2)|
            @registry.set_adjacent_pair(pair_key, cell1, cell2)
            transition_builder.call(cell1, cell2)
          end
        end

        def stale_pair_keys(next_pair_keys)
          next_pair_key_set = next_pair_keys.each_with_object({}) { |pair_key, set| set[pair_key] = true }
          (@registry.adjacent_pair_keys | @registry.transition_pair_keys).reject do |pair_key|
            next_pair_key_set[pair_key]
          end
        end

        def pair_keys_within(entries)
          cells = entries.map { |entry| entry[:cell_space] }
          keys = []
          cells.each_with_index do |cell1, index|
            cells[(index + 1)..].to_a.each do |cell2|
              pair_key = cell_pair_key(cell1, cell2)
              adjacent = if @registry.respond_to?(:adjacent_pair?)
                           @registry.adjacent_pair?(pair_key)
                         else
                           @registry.adjacent_pair_keys.include?(pair_key)
                         end
              transition = if @registry.respond_to?(:transition_for_pair)
                             !@registry.transition_for_pair(pair_key).nil?
                           else
                             @registry.transition_pair_keys.include?(pair_key)
                           end
              next unless adjacent || transition

              keys << pair_key
            end
          end
          keys
        end

        def transition_allowed_for_axis?(adjacency_axis)
          return !adjacency_axis.nil?
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def elapsed_since(started_at)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        end
      end

    end
  end
end
