# frozen_string_literal: true

require 'thread'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class ProgressMailbox
          def initialize
            @queue = Queue.new
          end

          def publish(event)
            payload = event.to_h.transform_keys(&:to_sym)
            payload[:published_at] ||= monotonic_time
            @queue << payload.freeze
            true
          end

          def drain
            events = []
            loop do
              events << @queue.pop(true)
            rescue ThreadError
              break
            end
            events
          end

          def empty?
            @queue.empty?
          end

          private

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end

        class CancellationToken
          def initialize
            @mutex = Mutex.new
            @cancelled = false
          end

          def cancel!
            @mutex.synchronize { @cancelled = true }
            true
          end

          def cancelled?
            @mutex.synchronize { @cancelled }
          end
        end

        class PureRubyWorker
          attr_reader :thread

          def initialize(mailbox:, cancellation_token:, total:, work_per_item:, progress_interval: 0.05,
                         yield_every: 4)
            @mailbox = mailbox
            @cancellation_token = cancellation_token
            @total = [total.to_i, 1].max
            @work_per_item = [work_per_item.to_i, 1].max
            @progress_interval = [progress_interval.to_f, 0.001].max
            @yield_every = [yield_every.to_i, 1].max
            @thread = nil
          end

          def start
            raise 'worker already started' if @thread

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

          private

          def run
            started_at = monotonic_time
            worker_thread_id = Thread.current.object_id
            completed = 0
            checksum = 0
            last_progress_at = started_at

            @mailbox.publish(
              type: :started,
              total: @total,
              completed: 0,
              percent: 0.0,
              worker_thread_id: worker_thread_id
            )

            @total.times do |index|
              break if @cancellation_token.cancelled?

              checksum = perform_pure_ruby_work(checksum, index)
              completed = index + 1
              now = monotonic_time

              if completed == @total || (now - last_progress_at) >= @progress_interval
                @mailbox.publish(
                  type: :progress,
                  total: @total,
                  completed: completed,
                  percent: completed.fdiv(@total) * 100.0,
                  elapsed: now - started_at,
                  worker_thread_id: worker_thread_id
                )
                last_progress_at = now
              end

              Thread.pass if (completed % @yield_every).zero?
            end

            finished_at = monotonic_time
            terminal_type = @cancellation_token.cancelled? ? :cancelled : :completed
            @mailbox.publish(
              type: terminal_type,
              total: @total,
              completed: completed,
              percent: completed.fdiv(@total) * 100.0,
              elapsed: finished_at - started_at,
              checksum: checksum,
              worker_thread_id: worker_thread_id
            )
          rescue StandardError => e
            @mailbox.publish(
              type: :failed,
              error_class: e.class.name,
              error_message: e.message,
              worker_thread_id: Thread.current.object_id
            )
          end

          def perform_pure_ruby_work(seed, item_index)
            value = (seed ^ item_index) & 0xFFFF_FFFF
            @work_per_item.times do |iteration|
              value = ((value * 1_664_525) + 1_013_904_223 + iteration) & 0xFFFF_FFFF
            end
            value
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end
    end
  end
end
