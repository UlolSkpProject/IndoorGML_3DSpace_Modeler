# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class CellSpaceConversionHistoryActionMonitor
          TERMINAL_TYPES = %i[completed failed].freeze

          def initialize(
            action:,
            expected_snapshot:,
            timeout_seconds: 5.0,
            stable_samples: 2,
            clock: nil
          )
            @action = action.to_sym
            raise ArgumentError, "unsupported history action: #{@action}" unless %i[undo redo].include?(@action)

            @expected_snapshot = normalize_snapshot(expected_snapshot).freeze
            @timeout_seconds = [timeout_seconds.to_f, 0.1].max
            @stable_samples_required = [stable_samples.to_i, 1].max
            @clock = clock || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            reset_state
          end

          def start
            return snapshot unless @type == :idle

            @started_at = now
            @type = :running
            snapshot
          end

          def tick(current_snapshot:, replay_pending:)
            start if @type == :idle
            return snapshot if terminal?

            @sample_count += 1
            @last_snapshot = normalize_snapshot(current_snapshot).freeze
            @replay_pending = replay_pending == true

            if !@replay_pending && @last_snapshot == @expected_snapshot
              @stable_match_count += 1
              finish!(:completed) if @stable_match_count >= @stable_samples_required
            else
              @stable_match_count = 0
            end

            fail!(:timeout) if !terminal? && elapsed >= @timeout_seconds
            snapshot
          end

          def fail!(reason)
            return snapshot if terminal?

            @error_reason = reason.to_sym
            finish!(:failed)
            snapshot
          end

          def running?
            @type == :running
          end

          def terminal?
            TERMINAL_TYPES.include?(@type)
          end

          def completed?
            @type == :completed
          end

          def failed?
            @type == :failed
          end

          def snapshot
            {
              type: @type,
              action: @action,
              terminal: terminal?,
              expected_snapshot: @expected_snapshot,
              last_snapshot: @last_snapshot,
              replay_pending: @replay_pending,
              sample_count: @sample_count,
              stable_match_count: @stable_match_count,
              stable_samples_required: @stable_samples_required,
              timeout_seconds: @timeout_seconds,
              elapsed: elapsed,
              error_reason: @error_reason
            }.freeze
          end

          private

          def reset_state
            @type = :idle
            @started_at = nil
            @finished_at = nil
            @last_snapshot = nil
            @replay_pending = false
            @sample_count = 0
            @stable_match_count = 0
            @error_reason = nil
          end

          def finish!(type)
            @type = type
            @finished_at = now
          end

          def elapsed
            return 0.0 unless @started_at

            (@finished_at || now) - @started_at
          end

          def normalize_snapshot(snapshot)
            Hash(snapshot).each_with_object({}) do |(key, value), normalized|
              normalized[key.to_sym] = value.to_i
            end
          end

          def now
            @clock.call.to_f
          end
        end
      end
    end
  end
end
