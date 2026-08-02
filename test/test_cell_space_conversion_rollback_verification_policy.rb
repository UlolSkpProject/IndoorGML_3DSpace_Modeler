# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/cell_space_conversion_rollback_verification_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionRollbackVerificationPolicyTest < Minitest::Test
        Policy =
          ThreadedProgressInfrastructure::
            CellSpaceConversionRollbackVerificationPolicy

        def test_abort_callback_is_consistent_rollback_diagnostic
          result = evaluate(observer_events: %i[start abort])

          assert result[:passed]
          assert_equal :abort_callback, result.dig(:observer, :rollback_signal)
          assert result.dig(:observer, :consistent)
        end

        def test_undo_callback_is_accepted_for_aborted_operation_runtime_pattern
          result = evaluate(observer_events: %i[start undo])

          assert result[:passed]
          assert_equal :undo_callback, result.dig(:observer, :rollback_signal)
          assert result.dig(:observer, :consistent)
          assert result.dig(:hard_gates, :transaction_not_committed)
        end

        def test_missing_rollback_callback_is_diagnostic_only_when_not_committed
          result = evaluate(observer_events: [:start])

          assert result[:passed]
          assert_equal :none, result.dig(:observer, :rollback_signal)
          refute result.dig(:observer, :consistent)
        end

        def test_commit_callback_fails_hard_gate
          result = evaluate(observer_events: %i[start commit])

          refute result[:passed]
          refute result.dig(:hard_gates, :transaction_not_committed)
        end

        def test_model_postcondition_failure_cannot_be_hidden_by_observer_signal
          result = evaluate(
            observer_events: %i[start abort],
            source_snapshot_unchanged: false
          )

          refute result[:passed]
          refute result.dig(:hard_gates, :source_snapshot_unchanged)
        end

        private

        def evaluate(observer_events:, **overrides)
          defaults = {
            expected_failure: true,
            unexpected_error: nil,
            injection_hits: 1,
            service_returned: false,
            root_entities_unchanged: true,
            feature_counts_unchanged: true,
            source_snapshot_unchanged: true,
            active_path_restored: true,
            replay_idle: true,
            observer_events: observer_events
          }
          Policy.new.evaluate(**defaults.merge(overrides))
        end
      end
    end
  end
end
