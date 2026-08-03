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

      class BulkCellSpaceConversionService
        def initialize(
          apply_guards:,
          operation_runner:,
          restore_active_path:,
          rollback:,
          logger:,
          calls:
        )
          @apply_guards = apply_guards
          @operation_runner = operation_runner
          @restore_active_path = restore_active_path
          @rollback = rollback
          @logger = logger
          @calls = calls
        end

        def call
          result = @apply_guards.call do
            @operation_runner.call(
              'Bulk Convert',
              rollback_if: proc { @rollback }
            ) do
              @calls << :work
              :result
            end
          end

          @calls << :runtime_restore if @rollback
          safely_restore_active_path(success: !@rollback)
          result
        end

        private

        def safely_restore_active_path(success:)
          @restore_active_path.call
        rescue StandardError => e
          context = success ? 'after commit' : 'during rollback'
          @logger.puts("#{context}: #{e.message}")
          nil
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
          FakeLogger = Struct.new(:messages) do
            def puts(message)
              messages << message
            end
          end

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

          def test_success_restores_active_path_once_before_guard_exits
            calls = []
            service = build_service(calls, rollback: false)

            result = service.call

            assert_equal :result, result
            assert_equal [
              :guard_enter,
              :operation_start,
              :work,
              :commit,
              :restore_active_path,
              :guard_exit
            ], calls
          end

          def test_rollback_keeps_restore_after_guard_and_runtime_restore
            calls = []
            service = build_service(calls, rollback: true)

            result = service.call

            assert_equal :result, result
            assert_equal [
              :guard_enter,
              :operation_start,
              :work,
              :abort,
              :guard_exit,
              :runtime_restore,
              :restore_active_path
            ], calls
          end

          private

          def build_service(calls, rollback:)
            logger = FakeLogger.new([])
            apply_guards = proc do |&block|
              calls << :guard_enter
              result = block.call
              calls << :guard_exit
              result
            end
            operation_runner = proc do |_name, rollback_if:, &block|
              calls << :operation_start
              result = block.call
              calls << (rollback_if.call ? :abort : :commit)
              result
            end
            restore_active_path = proc { calls << :restore_active_path }

            BulkCellSpaceConversionService.new(
              apply_guards: apply_guards,
              operation_runner: operation_runner,
              restore_active_path: restore_active_path,
              rollback: rollback,
              logger: logger,
              calls: calls
            )
          end
        end
      end
    end
  end
end
