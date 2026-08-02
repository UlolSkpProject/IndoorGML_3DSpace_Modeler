# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class MainThreadSliceRunner
          TERMINAL_TYPES = %i[completed cancelled failed].freeze
          DEFAULT_PREDICTION_SAFETY_FACTOR = 1.0
          DEFAULT_BUDGET_GUARD_MS = 0.25
          ITEM_DURATION_ALPHA = 0.25

          def initialize(
            total:,
            slice_budget_ms: 8.0,
            max_items_per_slice: 100,
            predictive_budget: false,
            prediction_safety_factor: DEFAULT_PREDICTION_SAFETY_FACTOR,
            budget_guard_ms: DEFAULT_BUDGET_GUARD_MS,
            clock: nil,
            &step
          )
            raise ArgumentError, 'step block is required' unless step

            @total = [total.to_i, 0].max
            @slice_budget_seconds = [slice_budget_ms.to_f / 1000.0, 0.0001].max
            @max_items_per_slice = [max_items_per_slice.to_i, 1].max
            @predictive_budget = predictive_budget == true
            @prediction_safety_factor = [prediction_safety_factor.to_f, 0.0].max
            @budget_guard_seconds = [budget_guard_ms.to_f / 1000.0, 0.0].max
            @clock = clock || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @step = step
            reset_state
          end

          def start
            return snapshot unless @type == :idle

            @started_at = now
            if @total.zero?
              @type = :completed
              @finished_at = @started_at
            else
              @type = :running
            end
            snapshot
          end

          def tick
            start if @type == :idle
            return snapshot if terminal?

            slice_started_at = now
            processed = 0

            begin
              while @completed < @total && processed < @max_items_per_slice
                break if @cancel_requested
                break if stop_before_next_item?(slice_started_at, processed)

                item_started_at = now
                value = @step.call(@completed)
                item_duration = [now - item_started_at, 0.0].max
                record_item_duration(item_duration)

                @last_value = value
                @checksum = combine_checksum(@checksum, value)
                @completed += 1
                processed += 1

                break if (now - slice_started_at) >= @slice_budget_seconds
              end

              if @cancel_requested
                finish!(:cancelled)
              elsif @completed >= @total
                finish!(:completed)
              end
            rescue StandardError => e
              @error_class = e.class.name
              @error_message = e.message
              finish!(:failed)
            ensure
              record_slice(slice_started_at, processed)
            end

            snapshot
          end

          def cancel!
            @cancel_requested = true
            true
          end

          def running?
            @type == :running
          end

          def terminal?
            TERMINAL_TYPES.include?(@type)
          end

          def snapshot
            current_time = @finished_at || now
            elapsed = @started_at ? current_time - @started_at : 0.0
            percent = @total.positive? ? @completed.fdiv(@total) * 100.0 : 100.0

            {
              type: @type,
              total: @total,
              completed: @completed,
              percent: [[percent, 0.0].max, 100.0].min,
              elapsed: elapsed,
              terminal: terminal?,
              cancel_requested: @cancel_requested,
              slice_budget_ms: @slice_budget_seconds * 1000.0,
              max_items_per_slice: @max_items_per_slice,
              predictive_budget: @predictive_budget,
              prediction_safety_factor: @prediction_safety_factor,
              budget_guard_ms: @budget_guard_seconds * 1000.0,
              estimated_item_ms: @estimated_item_duration * 1000.0,
              last_item_ms: @last_item_duration * 1000.0,
              max_item_ms: @max_item_duration * 1000.0,
              predictive_stop_count: @predictive_stop_count,
              slice_count: @slice_count,
              last_slice_items: @last_slice_items,
              max_slice_items: @max_slice_items,
              last_slice_ms: @last_slice_duration * 1000.0,
              max_slice_ms: @max_slice_duration * 1000.0,
              overrun_count: @overrun_count,
              checksum: @checksum,
              last_value: @last_value,
              error_class: @error_class,
              error_message: @error_message
            }.freeze
          end

          private

          def reset_state
            @type = :idle
            @completed = 0
            @cancel_requested = false
            @started_at = nil
            @finished_at = nil
            @slice_count = 0
            @last_slice_items = 0
            @max_slice_items = 0
            @last_slice_duration = 0.0
            @max_slice_duration = 0.0
            @overrun_count = 0
            @estimated_item_duration = 0.0
            @last_item_duration = 0.0
            @max_item_duration = 0.0
            @predictive_stop_count = 0
            @checksum = 0
            @last_value = nil
            @error_class = nil
            @error_message = nil
          end

          def stop_before_next_item?(slice_started_at, processed)
            return false unless @predictive_budget
            return false unless processed.positive?
            return false unless @estimated_item_duration.positive?

            elapsed = [now - slice_started_at, 0.0].max
            predicted_next = (@estimated_item_duration * @prediction_safety_factor) +
                             @budget_guard_seconds
            return false if (elapsed + predicted_next) < @slice_budget_seconds

            @predictive_stop_count += 1
            true
          end

          def record_item_duration(duration)
            @last_item_duration = duration
            @max_item_duration = [@max_item_duration, duration].max
            @estimated_item_duration = if @estimated_item_duration.zero?
                                         duration
                                       else
                                         ((1.0 - ITEM_DURATION_ALPHA) * @estimated_item_duration) +
                                           (ITEM_DURATION_ALPHA * duration)
                                       end
          end

          def finish!(type)
            @type = type
            @finished_at = now
          end

          def record_slice(started_at, processed)
            duration = [now - started_at, 0.0].max
            @slice_count += 1
            @last_slice_items = processed
            @max_slice_items = [@max_slice_items, processed].max
            @last_slice_duration = duration
            @max_slice_duration = [@max_slice_duration, duration].max
            @overrun_count += 1 if duration > @slice_budget_seconds
          end

          def combine_checksum(seed, value)
            integer = if value.is_a?(Numeric)
                        value.to_i
                      else
                        value.hash
                      end
            ((seed * 16_777_619) ^ integer) & 0xFFFF_FFFF
          end

          def now
            @clock.call.to_f
          end
        end
      end
    end
  end
end
