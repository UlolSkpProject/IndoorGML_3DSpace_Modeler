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

        def initialize(registry, transition_builder:, transition_eraser:)
          @registry = registry
          @transition_builder = transition_builder
          @transition_eraser = transition_eraser
        end

        def synchronize_for(cell_space)
          return if cell_space.nil? || !cell_space.valid? || !cell_space.duality_state&.valid?

          @registry.cell_spaces.each do |other_cell_space|
            next if other_cell_space.nil? || other_cell_space == cell_space
            next unless other_cell_space.valid? && other_cell_space.duality_state&.valid?

            pair_key = cell_pair_key(cell_space, other_cell_space)
            adjacency_axis = Utils::Geometry.adjacency_axis(cell_space.sketchup_group, other_cell_space.sketchup_group)
            if transition_allowed_between?(cell_space, other_cell_space, adjacency_axis)
              @registry.set_adjacent_pair(pair_key, cell_space, other_cell_space)
              @transition_builder.call(cell_space, other_cell_space)
            else
              @transition_eraser.call(pair_key)
            end
          end
        end

        def synchronize_all
          entries = adjacency_snapshot_entries
          return if entries.empty?

          pair_results = compute_pair_results(entries, tolerance: 1.mm)
          apply_pair_results(entries, pair_results)
        end

        def erase_for(cell_space)
          return if cell_space.nil?

          @registry.adjacent_pair_keys.each do |pair_key|
            @transition_eraser.call(pair_key) if pair_key.split(':').include?(cell_space.id)
          end

          @registry.transition_pair_keys.each do |pair_key|
            @transition_eraser.call(pair_key) if pair_key.split(':').include?(cell_space.id)
          end
        end

        def cell_pair_key(cell1, cell2)
          [cell1.id, cell2.id].sort.join(':')
        end

        private

        def adjacency_snapshot_entries
          @registry.cell_spaces.each_with_object([]) do |cell_space, entries|
            next if cell_space.nil? || !cell_space.valid?
            next unless cell_space.duality_state&.valid?

            snapshot = Utils::Geometry.adjacency_snapshot(cell_space.sketchup_group)
            next unless snapshot

            entries << { cell_space: cell_space, snapshot: snapshot }
          end.freeze
        end

        def compute_pair_results(entries, tolerance:)
          pair_indices = candidate_pair_indices(entries, tolerance)
          return [] if pair_indices.empty?

          if pair_indices.length < MIN_PARALLEL_PAIRS
            return compute_pair_chunk(entries, pair_indices, tolerance)
          end

          compute_pair_results_in_parallel(entries, pair_indices, tolerance)
        end

        def candidate_pair_indices(entries, tolerance)
          pairs = []
          count = entries.length
          (0...count).each do |index1|
            ((index1 + 1)...count).each do |index2|
              next unless candidate_bounds_touch?(
                entries[index1][:snapshot][:bounds],
                entries[index2][:snapshot][:bounds],
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

        def compute_pair_results_in_parallel(entries, pair_indices, tolerance)
          chunks = pair_indices.each_slice(PAIR_CHUNK_SIZE).to_a
          queue = Queue.new
          chunks.each { |chunk| queue << chunk }
          workers = [worker_count, chunks.length].min
          threads = workers.times.map do
            Thread.new do
              local_results = []
              loop do
                chunk = queue.pop(true)
                local_results.concat(compute_pair_chunk(entries, chunk, tolerance))
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

        def compute_pair_chunk(entries, pair_indices, tolerance)
          pair_indices.each_with_object([]) do |(index1, index2), results|
            axis = Utils::Geometry.adjacency_axis_from_snapshots(
              entries[index1][:snapshot],
              entries[index2][:snapshot],
              tolerance: tolerance
            )
            results << [index1, index2, axis] unless axis.nil?
          end
        end

        def apply_pair_results(entries, pair_results)
          next_pairs = {}
          pair_results.each do |index1, index2, adjacency_axis|
            cell1 = entries[index1][:cell_space]
            cell2 = entries[index2][:cell_space]
            next unless transition_allowed_between?(cell1, cell2, adjacency_axis)

            pair_key = cell_pair_key(cell1, cell2)
            next_pairs[pair_key] = [cell1, cell2]
          end

          stale_pair_keys(next_pairs.keys).each { |pair_key| @transition_eraser.call(pair_key) }
          next_pairs.each do |pair_key, (cell1, cell2)|
            @registry.set_adjacent_pair(pair_key, cell1, cell2)
            @transition_builder.call(cell1, cell2)
          end
        end

        def stale_pair_keys(next_pair_keys)
          next_pair_key_set = next_pair_keys.each_with_object({}) { |pair_key, set| set[pair_key] = true }
          (@registry.adjacent_pair_keys | @registry.transition_pair_keys).reject do |pair_key|
            next_pair_key_set[pair_key]
          end
        end

        def transition_allowed_between?(cell1, cell2, adjacency_axis)
          return !adjacency_axis.nil?
        end
      end

    end
  end
end
