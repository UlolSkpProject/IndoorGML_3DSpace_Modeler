# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/write_undo_mode_plan'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class WriteUndoModePlanTest < Minitest::Test
        Plan = ThreadedProgressInfrastructure::WriteUndoModePlan

        def test_safe_mode_is_default
          plan = Plan.new

          assert_equal :prepare_then_apply, plan.mode
          refute plan.risky?
          assert_equal :discard_plan, plan.cancellation_behavior
        end

        def test_risky_modes_require_explicit_opt_in
          assert_raises(ArgumentError) { Plan.new(mode: :held_operation) }
          assert_raises(ArgumentError) { Plan.new(mode: :transparent_slices) }

          assert Plan.new(mode: :held_operation, allow_risky: true).risky?
          assert Plan.new(mode: :transparent_slices, allow_risky: true).risky?
        end

        def test_unknown_mode_is_rejected
          assert_raises(ArgumentError) { Plan.new(mode: :unknown) }
        end

        def test_each_mode_has_a_distinct_cancellation_contract
          contracts = Plan::MODES.map do |mode|
            Plan.new(mode: mode, allow_risky: true).cancellation_behavior
          end

          assert_equal contracts.uniq, contracts
        end
      end
    end
  end
end
