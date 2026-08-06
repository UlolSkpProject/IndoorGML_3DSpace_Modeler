# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class AdjacencyService
        PROGRESS_UPDATE_STEP = 250

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

        def synchronize_all(transition_builder: nil, transition_eraser: nil, progress: nil)
          reset_run_metrics
          started_at = monotonic_time
          entries = adjacency_snapshot_entries(progress: progress)
          if entries.empty?
            @last_metrics = build_metrics(started_at)
            return @last_metrics
          end

          pair_results = compute_pair_results(
            entries,
            tolerance: Utils::Geometry::ADJACENCY_TOLERANCE,
            progress: progress
          )
          apply_started_at = monotonic_time
          apply_pair_results(
            entries,
            pair_results,
            transition_builder: transition_builder || @transition_builder,
            transition_eraser: transition_eraser || @transition_eraser,
            progress: progress
          )
          @last_transition_apply_duration = elapsed_since(apply_started_at)
          @last_metrics = build_metrics(started_at)
        end

        def synchronize_within(cell_spaces, transition_builder: nil, transition_eraser: nil, progress: nil)
          reset_run_metrics
          started_at = monotonic_time
          entries = adjacency_snapshot_entries(cell_spaces, progress: progress)
          pair_results = compute_pair_results(
            entries,
            tolerance: Utils::Geometry::ADJACENCY_TOLERANCE,
            progress: progress
          )
          apply_started_at = monotonic_time
          apply_pair_results(
            entries,
            pair_results,
            transition_builder: transition_builder || @transition_builder,
            transition_eraser: transition_eraser || @transition_eraser,
            stale_pair_keys: pair_keys_within(entries),
            progress: progress
          )
          @last_transition_apply_duration = elapsed_since(apply_started_at)
          @last_metrics = build_metrics(started_at)
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

        def adjacency_snapshot_entries(cell_spaces = @registry.cell_spaces, progress: nil)
          started_at = monotonic_time
          source_cells = Array(cell_spaces).uniq
          total = source_cells.length
          emit_stage_start(
            progress,
            stage: :snapshot,
            name: 'Adjacency 스냅샷',
            total: total,
            message: "Adjacency 스냅샷 생성: 0 / #{total}"
          )

          entries = []
          source_cells.each_with_index do |cell_space, index|
            if cell_space && cell_space.valid? && cell_space.duality_state&.valid?
              snapshot = Utils::Geometry.adjacency_snapshot(cell_space.sketchup_group)
              entries << { cell_space: cell_space, snapshot: snapshot } if snapshot
            end

            completed = index + 1
            emit_stage_progress(
              progress,
              stage: :snapshot,
              name: 'Adjacency 스냅샷',
              total: total,
              completed: completed,
              message: "Adjacency 스냅샷 생성: #{completed} / #{total}"
            ) if progress_checkpoint?(completed, total)
          end

          @last_snapshot_duration = elapsed_since(started_at)
          emit_stage_finish(
            progress,
            stage: :snapshot,
            name: 'Adjacency 스냅샷',
            total: total,
            completed: total,
            message: "Adjacency 스냅샷 완료: #{entries.length}개",
            telemetry: {
              source_cell_count: total,
              snapshot_count: entries.length,
              duration: @last_snapshot_duration
            }
          )
          entries.freeze
        end

        def compute_pair_results(entries, tolerance:, progress: nil)
          snapshots = entries.map { |entry| entry[:snapshot] }.freeze
          candidate_started_at = monotonic_time
          pair_indices = candidate_pair_indices(snapshots, tolerance, progress: progress)
          @last_candidate_generation_duration = elapsed_since(candidate_started_at)
          @last_pair_comparison_count = pair_indices.length
          return [] if pair_indices.empty?

          started_at = monotonic_time
          compute_pair_chunk(snapshots, pair_indices, tolerance, progress: progress)
        ensure
          @last_detailed_computation_duration = elapsed_since(started_at) if started_at
        end

        def candidate_pair_indices(snapshots, tolerance, progress: nil)
          pairs = []
          count = snapshots.length
          total = count * (count - 1) / 2
          completed = 0
          emit_stage_start(
            progress,
            stage: :candidate_generation,
            name: 'Adjacency 후보 생성',
            total: total,
            message: "Adjacency 후보 pair 생성: 0 / #{total}"
          )

          (0...count).each do |index1|
            ((index1 + 1)...count).each do |index2|
              if candidate_bounds_touch?(
                snapshots[index1][:bounds],
                snapshots[index2][:bounds],
                tolerance
              )
                pairs << [index1, index2]
              end

              completed += 1
              emit_stage_progress(
                progress,
                stage: :candidate_generation,
                name: 'Adjacency 후보 생성',
                total: total,
                completed: completed,
                message: "Adjacency 후보 pair 생성: #{completed} / #{total}"
              ) if progress_checkpoint?(completed, total)
            end
          end

          emit_stage_finish(
            progress,
            stage: :candidate_generation,
            name: 'Adjacency 후보 생성',
            total: total,
            completed: total,
            message: "Adjacency 후보 생성 완료: #{pairs.length}개",
            telemetry: {
              evaluated_pair_count: total,
              candidate_pair_count: pairs.length
            }
          )
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

        def compute_pair_chunk(snapshots, pair_indices, tolerance, progress: nil)
          total = pair_indices.length
          emit_stage_start(
            progress,
            stage: :detailed_computation,
            name: 'Adjacency 상세 판정',
            total: total,
            message: "Adjacency 상세 판정: 0 / #{total}"
          )

          results = []
          pair_indices.each_with_index do |(index1, index2), index|
            axis = Utils::Geometry.adjacency_axis_from_snapshots(
              snapshots[index1],
              snapshots[index2],
              tolerance: tolerance
            )
            results << [index1, index2, axis] unless axis.nil?

            completed = index + 1
            emit_stage_progress(
              progress,
              stage: :detailed_computation,
              name: 'Adjacency 상세 판정',
              total: total,
              completed: completed,
              message: "Adjacency 상세 판정: #{completed} / #{total}"
            ) if progress_checkpoint?(completed, total)
          end

          emit_stage_finish(
            progress,
            stage: :detailed_computation,
            name: 'Adjacency 상세 판정',
            total: total,
            completed: total,
            message: "Adjacency 상세 판정 완료: #{results.length}개 인접",
            telemetry: {
              candidate_pair_count: total,
              adjacent_pair_count: results.length
            }
          )
          results
        end

        def apply_pair_results(entries, pair_results, transition_builder:, transition_eraser:, stale_pair_keys: nil, progress: nil)
          next_pairs = {}
          pair_results.each do |index1, index2, adjacency_axis|
            cell1 = entries[index1][:cell_space]
            cell2 = entries[index2][:cell_space]
            next unless transition_allowed_for_axis?(adjacency_axis)

            pair_key = cell_pair_key(cell1, cell2)
            next_pairs[pair_key] = [cell1, cell2]
          end

          stale_keys = stale_pair_keys || self.stale_pair_keys(next_pairs.keys)
          erase_keys = stale_keys.reject { |pair_key| next_pairs.key?(pair_key) }
          total = erase_keys.length + next_pairs.length
          completed = 0
          emit_stage_start(
            progress,
            stage: :transition_apply,
            name: 'Transition 반영',
            total: total,
            message: "Transition 반영: 0 / #{total}"
          )

          erase_keys.each do |pair_key|
            transition_eraser.call(pair_key)
            completed += 1
            emit_stage_progress(
              progress,
              stage: :transition_apply,
              name: 'Transition 반영',
              total: total,
              completed: completed,
              message: "Transition 반영: #{completed} / #{total}"
            ) if progress_checkpoint?(completed, total)
          end
          next_pairs.each do |pair_key, (cell1, cell2)|
            @registry.set_adjacent_pair(pair_key, cell1, cell2)
            transition_builder.call(cell1, cell2)
            completed += 1
            emit_stage_progress(
              progress,
              stage: :transition_apply,
              name: 'Transition 반영',
              total: total,
              completed: completed,
              message: "Transition 반영: #{completed} / #{total}"
            ) if progress_checkpoint?(completed, total)
          end

          emit_stage_finish(
            progress,
            stage: :transition_apply,
            name: 'Transition 반영',
            total: total,
            completed: total,
            message: "Transition 반영 완료: 생성/갱신 #{next_pairs.length}개, 삭제 #{erase_keys.length}개",
            telemetry: {
              transition_upsert_count: next_pairs.length,
              transition_erase_count: erase_keys.length
            }
          )
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

        def reset_run_metrics
          @last_pair_comparison_count = 0
          @last_snapshot_duration = 0.0
          @last_candidate_generation_duration = 0.0
          @last_detailed_computation_duration = 0.0
          @last_transition_apply_duration = 0.0
          @last_progress_event_count = 0
          @last_progress_error_count = 0
        end

        def build_metrics(started_at)
          {
            total_duration: elapsed_since(started_at),
            pair_comparison_count: @last_pair_comparison_count.to_i,
            adjacency_snapshot_duration: @last_snapshot_duration.to_f,
            adjacency_candidate_generation: @last_candidate_generation_duration.to_f,
            adjacency_detailed_computation: @last_detailed_computation_duration.to_f,
            transition_apply: @last_transition_apply_duration.to_f,
            progress_event_count: @last_progress_event_count.to_i,
            progress_error_count: @last_progress_error_count.to_i
          }
        end

        def progress_checkpoint?(completed, total)
          return true if completed == 1
          return true if completed == total

          (completed % PROGRESS_UPDATE_STEP).zero?
        end

        def emit_stage_start(progress, stage:, name:, total:, message:)
          emit_progress(
            progress,
            event: :stage_start,
            stage: stage,
            name: name,
            total: total,
            completed: 0,
            message: message
          )
        end

        def emit_stage_progress(progress, stage:, name:, total:, completed:, message:)
          emit_progress(
            progress,
            event: :stage_progress,
            stage: stage,
            name: name,
            total: total,
            completed: completed,
            message: message
          )
        end

        def emit_stage_finish(progress, stage:, name:, total:, completed:, message:, telemetry: nil)
          emit_progress(
            progress,
            event: :stage_finish,
            stage: stage,
            name: name,
            total: total,
            completed: completed,
            message: message,
            telemetry: telemetry
          )
        end

        def emit_progress(progress, payload)
          return false unless progress&.respond_to?(:call)

          @last_progress_event_count = @last_progress_event_count.to_i + 1
          progress.call(payload.freeze)
          true
        rescue StandardError
          @last_progress_error_count = @last_progress_error_count.to_i + 1
          false
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
