# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/cell_space_conversion_apply_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionApplyPolicyTest < Minitest::Test
        Policy = ThreadedProgressInfrastructure::CellSpaceConversionApplyPolicy

        def test_allows_completed_error_free_plan_within_limit
          decision = Policy.new(max_apply_jobs: 5).evaluate(
            preflight_type: :completed,
            job_count: 3,
            plan_count: 3,
            error_count: 0
          )

          assert decision.allowed?
          assert_equal :allowed, decision.reason
        end

        def test_rejects_job_limit_exceeded
          decision = Policy.new(max_apply_jobs: 5).evaluate(
            preflight_type: :completed,
            job_count: 6,
            plan_count: 6,
            error_count: 0
          )

          refute decision.allowed?
          assert_equal :job_limit_exceeded, decision.reason
        end

        def test_rejects_preflight_errors_or_partial_plan
          policy = Policy.new(max_apply_jobs: 5)

          errors = policy.evaluate(
            preflight_type: :completed,
            job_count: 3,
            plan_count: 2,
            error_count: 1
          )
          mismatch = policy.evaluate(
            preflight_type: :completed,
            job_count: 3,
            plan_count: 2,
            error_count: 0
          )

          assert_equal :preflight_errors, errors.reason
          assert_equal :plan_count_mismatch, mismatch.reason
        end

        def test_rejects_non_completed_or_empty_preflight
          policy = Policy.new

          running = policy.evaluate(
            preflight_type: :running,
            job_count: 1,
            plan_count: 1,
            error_count: 0
          )
          empty = policy.evaluate(
            preflight_type: :completed,
            job_count: 0,
            plan_count: 0,
            error_count: 0
          )

          assert_equal :preflight_not_completed, running.reason
          assert_equal :no_jobs, empty.reason
        end
      end
    end
  end
end
