# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/read_only_work_plan'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ReadOnlyWorkPlanTest < Minitest::Test
        Plan = ThreadedProgressInfrastructure::ReadOnlyWorkPlan

        def test_single_pass_uses_actual_target_count_once
          plan = Plan.new(mode: :single_pass, target_count: 3, stress_iterations: 50_000)

          assert plan.single_pass?
          refute plan.stress?
          assert_equal 3, plan.total
          assert_equal [0, 1, 2], (0...plan.total).map { |index| plan.target_index(index) }
          assert_equal 'Entity', plan.count_label
        end

        def test_stress_mode_repeats_targets_to_requested_iteration_count
          plan = Plan.new(mode: :stress, target_count: 3, stress_iterations: 8)

          assert plan.stress?
          assert_equal 8, plan.total
          assert_equal [0, 1, 2, 0, 1, 2, 0, 1],
                       (0...plan.total).map { |index| plan.target_index(index) }
          assert_equal 'API 조회', plan.count_label
        end

        def test_invalid_mode_is_rejected
          error = assert_raises(ArgumentError) do
            Plan.new(mode: :unknown, target_count: 3, stress_iterations: 10)
          end

          assert_match(/unsupported read-only work mode/, error.message)
        end

        def test_empty_target_set_is_rejected
          assert_raises(ArgumentError) do
            Plan.new(mode: :single_pass, target_count: 0, stress_iterations: 10)
          end
        end

        def test_out_of_range_work_index_is_rejected
          plan = Plan.new(mode: :single_pass, target_count: 2, stress_iterations: 10)

          assert_raises(IndexError) { plan.target_index(-1) }
          assert_raises(IndexError) { plan.target_index(2) }
        end
      end
    end
  end
end
