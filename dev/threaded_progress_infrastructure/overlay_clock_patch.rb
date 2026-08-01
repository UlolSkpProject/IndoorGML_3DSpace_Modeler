# frozen_string_literal: true

require_relative 'overlay_prototype'
require_relative 'overlay_clock_state'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressOverlayPrototype
        DISPLAY_INTERVAL = 0.1 unless const_defined?(:DISPLAY_INTERVAL, false)

        class Controller
          unless method_defined?(:start_job_without_display_clock)
            alias_method :start_job_without_display_clock, :start_job
          end

          def start_job(total: DEFAULT_TOTAL, work_per_item: DEFAULT_WORK_PER_ITEM)
            return false if @worker&.alive?

            started_at = monotonic_time
            prepare_display_clock(started_at)
            result = start_job_without_display_clock(
              total: total,
              work_per_item: work_per_item
            )
            clear_display_clock unless result
            result
          end

          private

          def pump
            assert_main_thread!
            now = monotonic_time
            record_pump_timing(now)

            unless Sketchup.active_model.equal?(@registered_model)
              @cancellation_token&.cancel!
              @state.apply(type: :failed, error_message: '작업 중 활성 모델이 변경되었습니다.')
              update_display_clock(now)
              invalidate_registered_view
              finish_terminal_event
              return false
            end

            events = @mailbox&.drain || []
            unless events.empty?
              event = reduce_events(events)
              event_age = if event[:published_at]
                            [now - event[:published_at].to_f, 0.0].max
                          end
              @state.apply(
                event.merge(
                  queue_batch_size: events.length,
                  event_age: event_age
                )
              )
            end

            update_display_clock(now)
            if !events.empty? || display_due?(now)
              invalidate_registered_view
              @last_display_at = now
            end

            finish_terminal_event if @state.terminal?
            true
          rescue StandardError => e
            @state.apply(type: :failed, error_message: "#{e.class}: #{e.message}")
            update_display_clock(monotonic_time)
            invalidate_registered_view
            finish_terminal_event
            false
          end

          def prepare_display_clock(started_at)
            @display_clock_started_at = started_at
            @last_pump_at = nil
            @last_pump_gap = 0.0
            @max_pump_gap = 0.0
            @pump_count = 0
            @last_display_at = started_at
          end

          def clear_display_clock
            @display_clock_started_at = nil
            @last_pump_at = nil
            @last_pump_gap = 0.0
            @max_pump_gap = 0.0
            @pump_count = 0
            @last_display_at = nil
          end

          def record_pump_timing(now)
            gap = @last_pump_at ? now - @last_pump_at : 0.0
            @last_pump_at = now
            @last_pump_gap = [gap, 0.0].max
            @max_pump_gap = [@max_pump_gap.to_f, @last_pump_gap].max
            @pump_count = @pump_count.to_i + 1
          end

          def update_display_clock(now)
            elapsed = if @display_clock_started_at
                        [now - @display_clock_started_at, 0.0].max
                      else
                        @state.snapshot[:elapsed].to_f
                      end
            @state.tick_elapsed(
              elapsed: elapsed,
              pump_gap: @last_pump_gap.to_f,
              max_pump_gap: @max_pump_gap.to_f,
              pump_count: @pump_count.to_i
            )
          end

          def display_due?(now)
            return true unless @last_display_at

            (now - @last_display_at) >= DISPLAY_INTERVAL
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end
    end
  end
end

puts '[THREADED PROGRESS OVERLAY CLOCK PATCH] installed'
puts 'Start: ...::ThreadedProgressOverlayPrototype.start!'
puts 'Status fields: pump_gap, max_pump_gap, pump_count, event_age'
