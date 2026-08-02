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
        attr_reader :seen_progress

        def synchronize_all
          adjacency_snapshot_entries
          :ok
        end

        private

        def adjacency_snapshot_entries(_cell_spaces = [], progress: nil)
          @seen_progress = progress
          []
        end

        def compute_pair_results(entries, tolerance:, progress: nil)
          [entries, tolerance, progress]
        end

        def apply_pair_results(
          entries,
          pair_results,
          transition_builder:,
          transition_eraser:,
          stale_pair_keys: nil,
          progress: nil
        )
          [entries, pair_results, transition_builder, transition_eraser, stale_pair_keys, progress]
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

        def synchronize_within(_cell_spaces, **kwargs)
          @service.synchronize_all(**kwargs)
        end
      end
    end
  end
end

require_relative '../indoor3d/application/progress/adjacency_progress_keyword_guard'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class AdjacencyProgressKeywordGuardTest < Minitest::Test
          def test_stale_integration_cannot_forward_progress_keyword
            sink = Object.new
            service = AdjacencyService.new
            coordinator = TopologyCoordinator.new(service)

            result = AdjacencyProgressContext.with(sink) do
              coordinator.synchronize_all
            end

            assert_equal :ok, result
            assert_same sink, service.seen_progress
          end

          def test_explicit_progress_keyword_is_consumed_before_service_call
            sink = Object.new
            service = AdjacencyService.new
            coordinator = TopologyCoordinator.new(service)

            result = coordinator.synchronize_all(progress: sink)

            assert_equal :ok, result
            assert_same sink, service.seen_progress
          end
        end
      end
    end
  end
end
