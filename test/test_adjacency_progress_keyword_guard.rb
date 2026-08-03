# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module AdjacencyProgressContext
          THREAD_KEY = :test_adjacency_progress_context

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(value)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = value
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end

        module TopologyCoordinatorProgressIntegration
          def synchronize_all(**kwargs)
            sink = AdjacencyProgressContext.current
            kwargs = kwargs.merge(progress: sink) if sink
            super(**kwargs)
          end
        end
      end

      class AdjacencyService
        attr_reader :seen_progress, :events, :checkpoint_during_run

        def initialize
          @events = []
        end

        def synchronize_all
          entries = adjacency_snapshot_entries(progress: Object.new)
          pair_results = compute_pair_results(entries, tolerance: 0.01, progress: Object.new)
          apply_pair_results(
            entries,
            pair_results,
            transition_builder: proc {},
            transition_eraser: proc {},
            progress: Object.new
          )
          @checkpoint_during_run = progress_checkpoint?(2, 10)
          :ok
        end

        def synchronize_within(_cell_spaces)
          synchronize_all
        end

        private

        def adjacency_snapshot_entries
          emit_stage_start(
            nil,
            stage: :snapshot,
            name: 'Adjacency 스냅샷',
            total: 1,
            message: 'snapshot'
          )
          [:snapshot]
        end

        def compute_pair_results(entries, tolerance:)
          pair_indices = candidate_pair_indices(entries, tolerance, progress: Object.new)
          compute_pair_chunk(entries, pair_indices, tolerance, progress: Object.new)
        end

        def candidate_pair_indices(_snapshots, _tolerance)
          emit_stage_progress(
            nil,
            stage: :candidate_generation,
            name: 'Adjacency 후보 생성',
            total: 2,
            completed: 1,
            message: 'candidate'
          )
          [[0, 0]]
        end

        def compute_pair_chunk(_snapshots, pair_indices, _tolerance)
          emit_stage_progress(
            nil,
            stage: :detailed_computation,
            name: 'Adjacency 상세 판정',
            total: pair_indices.length,
            completed: 1,
            message: 'detail'
          )
          [[0, 0, :x]]
        end

        def apply_pair_results(
          _entries,
          pair_results,
          transition_builder:,
          transition_eraser:,
          stale_pair_keys: nil
        )
          transition_builder.call
          transition_eraser.call if stale_pair_keys == :erase
          emit_stage_finish(
            nil,
            stage: :transition_apply,
            name: 'Transition 반영',
            total: pair_results.length,
            completed: pair_results.length,
            message: 'apply'
          )
          true
        end

        def emit_stage_start(progress, **payload)
          @seen_progress = progress
          @events << [:start, progress, payload]
        end

        def emit_stage_progress(progress, **payload)
          @seen_progress = progress
          @events << [:progress, progress, payload]
        end

        def emit_stage_finish(progress, **payload)
          @seen_progress = progress
          @events << [:finish, progress, payload]
        end

        def progress_checkpoint?(_completed, _total)
          false
        end
      end

      class TopologyCoordinator
        prepend ProductionProgress::TopologyCoordinatorProgressIntegration

        def initialize(service)
          @service = service
        end

        def synchronize_all(**kwargs)
          @service.synchronize_all(**kwargs)
        end

        def synchronize_within(cell_spaces, **kwargs)
          @service.synchronize_within(cell_spaces, **kwargs)
        end
      end

      class IndoorModel; end
    end
  end
end

require_relative '../indoor3d/application/progress/adjacency_progress_keyword_guard'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class AdjacencyProgressKeywordGuardTest < Minitest::Test
          def test_complete_internal_chain_strips_keywords_and_emits_visible_stages
            sink = Object.new
            service = AdjacencyService.new
            coordinator = TopologyCoordinator.new(service)

            result = AdjacencyProgressContext.with(sink) do
              coordinator.synchronize_all
            end

            assert_equal :ok, result
            assert_equal %i[progress finish], service.events.map(&:first)
            assert_equal %i[detailed_computation transition_apply], service.events.map { |event| event[2][:stage] }
            assert service.events.all? { |event| event[1].equal?(sink) }
            assert service.checkpoint_during_run
          end

          def test_explicit_progress_keyword_is_consumed_before_service_call
            sink = Object.new
            service = AdjacencyService.new
            coordinator = TopologyCoordinator.new(service)

            result = coordinator.synchronize_all(progress: sink)

            assert_equal :ok, result
            assert_same sink, service.seen_progress
          end

          def test_without_progress_keeps_default_checkpoint_policy
            service = AdjacencyService.new

            refute service.send(:progress_checkpoint?, 2, 10)
          end
        end
      end
    end
  end
end
