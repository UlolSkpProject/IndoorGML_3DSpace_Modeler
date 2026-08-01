# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/overlay_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ThreadedProgressOverlayStateTest < Minitest::Test
        State = ThreadedProgressInfrastructure::OverlayState

        def setup
          @state = State.new
        end

        def test_idle_state_is_hidden
          refute @state.visible?
          refute @state.terminal?
          assert_equal :idle, @state.snapshot[:type]
          assert @state.snapshot.frozen?
        end

        def test_started_event_becomes_visible
          @state.apply(type: :started, total: 10, completed: 0)

          assert @state.visible?
          refute @state.terminal?
          assert_equal 0.0, @state.snapshot[:percent]
          assert_equal '순수 Ruby worker 실행 중', @state.snapshot[:message]
        end

        def test_progress_is_normalized_and_clamped
          @state.apply(type: :progress, total: 10, completed: 12, percent: 180)

          assert_equal 10, @state.snapshot[:completed]
          assert_equal 100.0, @state.snapshot[:percent]

          @state.apply(type: :progress, total: 10, completed: 3, percent: nil)
          assert_in_delta 30.0, @state.snapshot[:percent], 0.0001
        end

        def test_terminal_event_remains_visible_until_hidden
          @state.apply(type: :completed, total: 4, completed: 4, elapsed: 1.25)

          assert @state.visible?
          assert @state.terminal?
          assert_equal '작업 완료', @state.snapshot[:message]

          @state.hide!
          refute @state.visible?
          assert @state.terminal?
        end

        def test_failure_preserves_error_message
          @state.apply(type: :failed, error_message: 'boom')

          assert @state.terminal?
          assert_equal '작업 실패: boom', @state.snapshot[:message]
        end

        def test_reset_returns_to_idle
          @state.apply(type: :progress, total: 5, completed: 2)
          @state.reset!

          refute @state.visible?
          refute @state.terminal?
          assert_equal :idle, @state.snapshot[:type]
        end
      end
    end
  end
end
