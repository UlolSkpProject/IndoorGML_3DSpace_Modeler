# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/cell_space_conversion_history_action_monitor'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionHistoryActionMonitorTest < Minitest::Test
        Monitor = ThreadedProgressInfrastructure::CellSpaceConversionHistoryActionMonitor

        def test_waits_while_transaction_replay_is_pending
          clock = FakeClock.new
          monitor = build_monitor(clock: clock)
          monitor.start

          clock.advance(0.1)
          snapshot = monitor.tick(
            current_snapshot: expected_snapshot,
            replay_pending: true
          )

          assert_equal :running, snapshot[:type]
          assert_equal 0, snapshot[:stable_match_count]
          assert snapshot[:replay_pending]
        end

        def test_completes_after_required_stable_samples
          clock = FakeClock.new
          monitor = build_monitor(clock: clock, stable_samples: 2)
          monitor.start

          clock.advance(0.1)
          first = monitor.tick(
            current_snapshot: expected_snapshot,
            replay_pending: false
          )
          clock.advance(0.1)
          second = monitor.tick(
            current_snapshot: expected_snapshot,
            replay_pending: false
          )

          assert_equal :running, first[:type]
          assert_equal 1, first[:stable_match_count]
          assert_equal :completed, second[:type]
          assert_equal 2, second[:stable_match_count]
        end

        def test_mismatch_resets_stable_sample_count
          clock = FakeClock.new
          monitor = build_monitor(clock: clock, stable_samples: 2)
          monitor.start

          clock.advance(0.1)
          monitor.tick(current_snapshot: expected_snapshot, replay_pending: false)
          clock.advance(0.1)
          mismatch = monitor.tick(
            current_snapshot: expected_snapshot.merge(cell_spaces: 5),
            replay_pending: false
          )

          assert_equal :running, mismatch[:type]
          assert_equal 0, mismatch[:stable_match_count]
        end

        def test_times_out_without_expected_snapshot
          clock = FakeClock.new
          monitor = build_monitor(clock: clock, timeout_seconds: 1.0)
          monitor.start

          clock.advance(1.1)
          snapshot = monitor.tick(
            current_snapshot: expected_snapshot.merge(states: 5),
            replay_pending: false
          )

          assert_equal :failed, snapshot[:type]
          assert_equal :timeout, snapshot[:error_reason]
          assert snapshot[:terminal]
        end

        def test_external_failure_preserves_reason
          clock = FakeClock.new
          monitor = build_monitor(clock: clock)
          monitor.start

          snapshot = monitor.fail!(:active_model_changed)

          assert_equal :failed, snapshot[:type]
          assert_equal :active_model_changed, snapshot[:error_reason]
        end

        private

        def expected_snapshot
          {
            cell_spaces: 0,
            states: 0,
            transitions: 0
          }
        end

        def build_monitor(clock:, stable_samples: 2, timeout_seconds: 5.0)
          Monitor.new(
            action: :undo,
            expected_snapshot: expected_snapshot,
            stable_samples: stable_samples,
            timeout_seconds: timeout_seconds,
            clock: proc { clock.now }
          )
        end

        class FakeClock
          attr_reader :now

          def initialize
            @now = 0.0
          end

          def advance(seconds)
            @now += seconds.to_f
          end
        end
      end
    end
  end
end
