# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        module AdjacencyProgressContext
          THREAD_KEY = :test_adaptive_adjacency_progress_context

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
    end
  end
end

require_relative '../indoor3d/application/progress/adjacency_progress_keyword_guard'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class AdaptiveAdjacencyProgressCheckpointHost
          prepend AdjacencyServiceProgressContextBridge

          private

          def progress_checkpoint?(_completed, _total)
            false
          end
        end

        class AdaptiveAdjacencyProgressCheckpointTest < Minitest::Test
          def setup
            @service = AdaptiveAdjacencyProgressCheckpointHost.new
            @sink = Object.new
          end

          def checkpoint(completed, total)
            AdjacencyProgressExecutionContext.with(@sink) do
              @service.send(:progress_checkpoint?, completed, total)
            end
          end

          def step(total)
            AdjacencyProgressExecutionContext.with(@sink) do
              @service.send(:adaptive_progress_update_step, total)
            end
          end

          def test_selects_nice_steps_for_about_five_hundred_updates
            assert_equal 1, step(320)
            assert_equal 2, step(780)
            assert_equal 10, step(4_200)
            assert_equal 20, step(8_500)
            assert_equal 50, step(24_000)
            assert_equal 200, step(80_000)
          end

          def test_checkpoint_uses_adaptive_step
            assert checkpoint(1, 24_000)
            assert checkpoint(50, 24_000)
            refute checkpoint(51, 24_000)
            assert checkpoint(24_000, 24_000)
          end

          def test_small_stage_updates_every_count
            assert checkpoint(2, 320)
            assert checkpoint(319, 320)
          end

          def test_without_progress_uses_original_policy
            refute @service.send(:progress_checkpoint?, 2, 320)
          end

          def test_invalid_counts_do_not_emit
            refute checkpoint(0, 100)
            refute checkpoint(1, 0)
          end
        end
      end
    end
  end
end
