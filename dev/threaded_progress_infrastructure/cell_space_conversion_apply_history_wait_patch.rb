# frozen_string_literal: true

require_relative 'cell_space_conversion_apply_history_guard_patch'
require_relative 'cell_space_conversion_history_action_monitor'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        class Controller
          HISTORY_POLL_INTERVAL = 0.05 unless const_defined?(:HISTORY_POLL_INTERVAL, false)
          HISTORY_TIMEOUT_SECONDS = 5.0 unless const_defined?(:HISTORY_TIMEOUT_SECONDS, false)
          HISTORY_STABLE_SAMPLES = 2 unless const_defined?(:HISTORY_STABLE_SAMPLES, false)

          unless method_defined?(:start_apply_job_without_history_wait)
            alias_method :start_apply_job_without_history_wait, :start_apply_job
          end
          unless method_defined?(:status_without_history_wait)
            alias_method :status_without_history_wait, :status
          end
          unless method_defined?(:verify_apply_without_history_wait)
            alias_method :verify_apply_without_history_wait, :verify_apply
          end
          unless method_defined?(:undo_apply_without_history_wait)
            alias_method :undo_apply_without_history_wait, :undo_apply
          end
          unless method_defined?(:redo_apply_without_history_wait)
            alias_method :redo_apply_without_history_wait, :redo_apply
          end
          unless method_defined?(:close_without_history_wait)
            alias_method :close_without_history_wait, :close
          end

          def start_apply_job(**options)
            stop_history_monitor
            @history_monitor = nil
            @history_action_error = nil
            start_apply_job_without_history_wait(**options)
          end

          def status
            base = status_without_history_wait
            monitor_snapshot = @history_monitor&.snapshot || {}
            snapshot = base.merge(
              history_action: monitor_snapshot[:action],
              history_monitor_type: monitor_snapshot[:type],
              history_monitor_elapsed: monitor_snapshot[:elapsed],
              history_monitor_samples: monitor_snapshot[:sample_count],
              history_monitor_stable_matches: monitor_snapshot[:stable_match_count],
              history_monitor_replay_pending: monitor_snapshot[:replay_pending],
              history_monitor_timer_active: !@history_monitor_timer_id.nil?,
              history_action_error: @history_action_error,
              transaction_replay_pending: @indoor_model&.transaction_replay_pending? == true
            ).freeze
            puts "[CELLSPACE APPLY HISTORY WAIT] #{snapshot.inspect}"
            snapshot
          end

          def verify_apply(expected = :converted)
            expected = expected.to_sym
            if expected == :undone && apply_history_state.position == :undo_requested
              return history_pending_verification(:undone, :undo_pending)
            end
            if expected == :redone && apply_history_state.position == :redo_requested
              return history_pending_verification(:redone, :redo_pending)
            end

            verify_apply_without_history_wait(expected)
          end

          def undo_apply
            assert_main_thread!
            started = undo_apply_without_history_wait
            return false unless started

            schedule_history_monitor(:undo)
          rescue StandardError => e
            apply_history_state.reject_undo_request!
            @history_action_error = "#{e.class}: #{e.message}"
            puts "[CELLSPACE APPLY HISTORY WAIT] Undo monitor start failed: #{@history_action_error}"
            false
          end

          def redo_apply
            assert_main_thread!
            started = redo_apply_without_history_wait
            return false unless started

            schedule_history_monitor(:redo)
          rescue StandardError => e
            apply_history_state.reject_redo_request!
            @history_action_error = "#{e.class}: #{e.message}"
            puts "[CELLSPACE APPLY HISTORY WAIT] Redo monitor start failed: #{@history_action_error}"
            false
          end

          def close
            stop_history_monitor
            close_without_history_wait
          end

          private

          def schedule_history_monitor(action)
            stop_history_monitor
            expected_snapshot = action == :undo ? @before_feature_counts : @after_feature_counts
            raise "#{action} expected snapshot is unavailable" unless expected_snapshot.is_a?(Hash)

            @history_action_error = nil
            @history_monitor =
              ThreadedProgressInfrastructure::CellSpaceConversionHistoryActionMonitor.new(
                action: action,
                expected_snapshot: expected_snapshot,
                timeout_seconds: HISTORY_TIMEOUT_SECONDS,
                stable_samples: HISTORY_STABLE_SAMPLES
              )
            @history_monitor.start
            @history_monitor_timer_id = UI.start_timer(HISTORY_POLL_INTERVAL, true) do
              pump_history_monitor
            end
            puts "[CELLSPACE APPLY HISTORY WAIT] #{action} dispatched; asynchronous verification started"
            true
          end

          def pump_history_monitor
            assert_main_thread!
            monitor = @history_monitor
            return stop_history_monitor_timer unless monitor&.running?

            unless Sketchup.active_model.equal?(@job_model)
              monitor.fail!(:active_model_changed)
            else
              indoor_model = @indoor_model || IndoorModel.current
              monitor.tick(
                current_snapshot: feature_counts(indoor_model),
                replay_pending: indoor_model.transaction_replay_pending?
              )
            end

            snapshot = monitor.snapshot
            if snapshot[:type] == :completed
              confirm_history_monitor(snapshot)
            elsif snapshot[:type] == :failed
              reject_history_monitor(snapshot)
            end
            true
          rescue StandardError => e
            @history_monitor&.fail!(:monitor_error)
            @history_action_error = "#{e.class}: #{e.message}"
            reject_history_monitor(@history_monitor&.snapshot || {})
            false
          end

          def confirm_history_monitor(snapshot)
            action = snapshot[:action]
            confirmed = if action == :undo
                          apply_history_state.confirm_undone!(matches: true)
                        else
                          apply_history_state.confirm_redone!(matches: true)
                        end
            unless confirmed
              @history_action_error = "#{action} history state confirmation failed"
              return reject_history_monitor(snapshot)
            end

            stop_history_monitor_timer
            @history_action_error = nil
            puts format(
              '[CELLSPACE APPLY HISTORY WAIT] %s confirmed in %.3f sec (%d samples)',
              action,
              snapshot[:elapsed].to_f,
              snapshot[:sample_count].to_i
            )
            verify_apply(action == :undo ? :undone : :redone)
            invalidate_view
            true
          end

          def reject_history_monitor(snapshot)
            action = snapshot[:action]
            if action == :undo
              apply_history_state.reject_undo_request!
            elsif action == :redo
              apply_history_state.reject_redo_request!
            end
            stop_history_monitor_timer
            reason = snapshot[:error_reason] || :unknown
            @history_action_error ||= reason.to_s
            puts format(
              '[CELLSPACE APPLY HISTORY WAIT] %s verification failed after %.3f sec: %s',
              action || :unknown,
              snapshot[:elapsed].to_f,
              @history_action_error
            )
            invalidate_view
            false
          end

          def history_pending_verification(expected, reason)
            current = feature_counts(@indoor_model || IndoorModel.current)
            monitor_snapshot = @history_monitor&.snapshot || {}
            payload = {
              expected: expected,
              converted_count: @apply_result ? @apply_result.converted_count.to_i : 0,
              apply_phase: @apply_phase,
              apply_history_position: apply_history_state.position,
              apply_history_available: apply_history_state.apply_recorded?,
              reason: reason,
              history_monitor_type: monitor_snapshot[:type],
              history_monitor_elapsed: monitor_snapshot[:elapsed],
              history_monitor_replay_pending: monitor_snapshot[:replay_pending],
              feature_counts_before: @before_feature_counts,
              feature_counts_after_apply: @after_feature_counts,
              feature_counts_current: current,
              passed: false
            }.freeze
            puts "[CELLSPACE PROGRESS APPLY VERIFY] #{payload.inspect}"
            payload
          end

          def stop_history_monitor
            stop_history_monitor_timer
            @history_monitor = nil
          end

          def stop_history_monitor_timer
            timer_id = @history_monitor_timer_id
            @history_monitor_timer_id = nil
            return false if timer_id.nil?

            UI.stop_timer(timer_id) if UI.respond_to?(:stop_timer)
            true
          rescue StandardError
            false
          end
        end
      end
    end
  end
end

puts '[CELLSPACE CONVERSION APPLY HISTORY WAIT PATCH] installed'
