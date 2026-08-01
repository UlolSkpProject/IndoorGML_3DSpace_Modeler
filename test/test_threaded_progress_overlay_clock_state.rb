# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/overlay_clock_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ThreadedProgressOverlayClockStateTest < Minitest::Test
        State = ThreadedProgressInfrastructure::OverlayState

        def setup
          @state = State.new
          @state.apply(
            type: :progress,
            total: 100,
            completed: 10,
            percent: 10.0,
            elapsed: 1.0
          )
        end

        def test_elapsed_tick_preserves_work_progress
          @state.tick_elapsed(
            elapsed: 2.5,
            pump_gap: 0.1,
            max_pump_gap: 0.3,
            pump_count: 4
          )

          snapshot = @state.snapshot
          assert_equal 10, snapshot[:completed]
          assert_equal 10.0, snapshot[:percent]
          assert_equal 2.5, snapshot[:elapsed]
          assert_equal 0.1, snapshot[:pump_gap]
          assert_equal 0.3, snapshot[:max_pump_gap]
          assert_equal 4, snapshot[:pump_count]
          assert snapshot.frozen?
        end

        def test_elapsed_never_moves_backwards
          @state.tick_elapsed(elapsed: 5.0)
          @state.tick_elapsed(elapsed: 3.0)

          assert_equal 5.0, @state.snapshot[:elapsed]
        end
      end
    end
  end
end
