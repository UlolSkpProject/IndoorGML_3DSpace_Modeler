# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module AdjacencyProgressContext
          THREAD_KEY = :test_cell_space_progress_overlay_policy

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
      end

      class AdjacencyService
        attr_reader :events

        def initialize
          @events = []
        end

        private

        def emit_stage_start(progress = nil, **payload)
          @events << [:start, progress, payload]
          true
        end

        def emit_stage_progress(progress = nil, **payload)
          @events << [:progress, progress, payload]
          true
        end

        def emit_stage_finish(progress = nil, **payload)
          @events << [:finish, progress, payload]
          true
        end

        def progress_checkpoint?(_completed, _total)
          false
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
        class CellSpaceProgressOverlayPolicyTest < Minitest::Test
          def test_snapshot_and_candidate_events_do_not_reach_overlay_sink
            service = AdjacencyService.new
            sink = Object.new

            AdjacencyProgressExecutionContext.with(sink) do
              %i[snapshot candidate_generation].each do |stage|
                service.send(:emit_stage_start, nil, stage: stage)
                service.send(:emit_stage_progress, nil, stage: stage)
                service.send(:emit_stage_finish, nil, stage: stage)
              end
            end

            assert_empty service.events
          end

          def test_detailed_and_transition_events_still_reach_overlay_sink
            service = AdjacencyService.new
            sink = Object.new

            AdjacencyProgressExecutionContext.with(sink) do
              service.send(:emit_stage_start, nil, stage: :detailed_computation)
              service.send(:emit_stage_progress, nil, stage: :detailed_computation)
              service.send(:emit_stage_finish, nil, stage: :transition_apply)
            end

            assert_equal %i[start progress finish], service.events.map(&:first)
            assert service.events.all? { |event| event[1].equal?(sink) }
          end
        end
      end
    end
  end
end
