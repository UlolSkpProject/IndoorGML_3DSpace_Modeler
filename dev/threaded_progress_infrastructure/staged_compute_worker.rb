# frozen_string_literal: true

require_relative 'core'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class StagedComputeWorker
          attr_reader :thread

          def initialize(inputs:, mailbox:, cancellation_token:, progress_interval: 0.1, &compute_step)
            raise ArgumentError, 'compute_step block is required' unless compute_step

            @inputs = inputs.freeze
            @mailbox = mailbox
            @cancellation_token = cancellation_token
            @progress_interval = [progress_interval.to_f, 0.01].max
            @compute_step = compute_step
            @thread = nil
            @result_mutex = Mutex.new
            @results = nil
          end

          def start
            raise 'compute worker already started' if @thread

            @thread = Thread.new { run }
            @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
            @thread
          end

          def alive?
            @thread&.alive? == true
          end

          def join(timeout = nil)
            @thread&.join(timeout)
          end

          def results
            raise 'compute worker is still running' if alive?

            @result_mutex.synchronize { @results }
          end

          private

          def run
            started_at = monotonic_time
            total = @inputs.length
            completed = 0
            output = Array.new(total)
            last_progress_at = started_at

            @mailbox.publish(
              type: :started,
              phase: :compute,
              total: total,
              completed: 0,
              percent: total.zero? ? 100.0 : 0.0,
              elapsed: 0.0,
              worker_thread_id: Thread.current.object_id
            )

            @inputs.each_with_index do |input, index|
              break if @cancellation_token.cancelled?

              output[index] = @compute_step.call(input, index)
              completed = index + 1
              now = monotonic_time
              next unless completed == total || (now - last_progress_at) >= @progress_interval

              publish_progress(total, completed, started_at, now)
              last_progress_at = now
              Thread.pass
            end

            terminal_type = @cancellation_token.cancelled? ? :cancelled : :completed
            if terminal_type == :completed
              frozen_output = output.map { |item| deep_freeze(item) }.freeze
              @result_mutex.synchronize { @results = frozen_output }
            end

            finished_at = monotonic_time
            @mailbox.publish(
              type: terminal_type,
              phase: :compute,
              total: total,
              completed: completed,
              percent: percent(total, completed),
              elapsed: finished_at - started_at,
              worker_thread_id: Thread.current.object_id,
              result_count: terminal_type == :completed ? total : 0
            )
          rescue StandardError => e
            @mailbox.publish(
              type: :failed,
              phase: :compute,
              error_class: e.class.name,
              error_message: e.message,
              worker_thread_id: Thread.current.object_id
            )
          end

          def publish_progress(total, completed, started_at, now)
            @mailbox.publish(
              type: :progress,
              phase: :compute,
              total: total,
              completed: completed,
              percent: percent(total, completed),
              elapsed: now - started_at,
              worker_thread_id: Thread.current.object_id
            )
          end

          def percent(total, completed)
            return 100.0 if total.zero?

            [[completed.to_f.fdiv(total) * 100.0, 0.0].max, 100.0].min
          end

          def deep_freeze(value)
            case value
            when Array
              value.each { |item| deep_freeze(item) }
            when Hash
              value.each do |key, item|
                deep_freeze(key)
                deep_freeze(item)
              end
            end
            value.freeze
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end
    end
  end
end
