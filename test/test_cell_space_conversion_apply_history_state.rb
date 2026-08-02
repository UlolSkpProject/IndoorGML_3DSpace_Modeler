# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/cell_space_conversion_apply_history_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionApplyHistoryStateTest < Minitest::Test
        State = ThreadedProgressInfrastructure::CellSpaceConversionApplyHistoryState

        def test_blocked_run_rejects_undo_and_redo
          state = State.new

          refute state.apply_recorded?
          refute state.request_undo!
          refute state.request_redo!
          assert_equal :not_applied, state.position
        end

        def test_successful_apply_requires_verified_undo_before_redo
          state = State.new
          state.mark_applied!

          assert state.request_undo!
          assert_equal :undo_requested, state.position
          refute state.request_redo!
          assert state.confirm_undone!(matches: true)
          assert_equal :undone, state.position
          assert state.request_redo!
          assert_equal :redo_requested, state.position
          assert state.confirm_redone!(matches: true)
          assert_equal :redone, state.position
        end

        def test_failed_undo_verification_restores_applied_position
          state = State.new
          state.mark_applied!
          state.request_undo!

          refute state.confirm_undone!(matches: false)
          assert_equal :applied, state.position
          assert state.undo_allowed?
        end

        def test_failed_redo_verification_restores_undone_position
          state = State.new
          state.mark_applied!
          state.request_undo!
          state.confirm_undone!(matches: true)
          state.request_redo!

          refute state.confirm_redone!(matches: false)
          assert_equal :undone, state.position
          assert state.redo_allowed?
        end

        def test_double_undo_is_rejected_until_redo_is_verified
          state = State.new
          state.mark_applied!
          state.request_undo!
          state.confirm_undone!(matches: true)

          refute state.request_undo!
          assert state.request_redo!
          state.confirm_redone!(matches: true)
          assert state.request_undo!
        end
      end
    end
  end
end
