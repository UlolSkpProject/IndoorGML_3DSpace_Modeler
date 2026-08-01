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

          def initialize(mailbox:, cancellation_token:, total:, work_per_item:, progress_interval: 0.1,
                         yield_interval: 0.01, checkpoint_iterations: 2_048)
            @mailbox = mailbox
            @cancellation_token = cancellation_token
            @total = [total.to_i, 1].max
            @work_per_item = [work_per_item.to_i, 1].max
            @progress_interval = [progress_interval.to_f, 0.001].max
            @yield_interval = [yield_interval.to_f, 0.001].max
            @checkpoint_iterations = [checkpoint_iterations.to_i, 1].max
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
            last_yield_at = started_at
            yield_count = 0
            checkpoint_count = 0
            progress_event_count = 0

            @mailbox.publish(
              type: :started,
              total: @total,
              completed: 0,
              percent: 0.0,
              elapsed: 0.0,
              worker_thread_id: worker_thread_id
            )

            checkpoint = lambda do
              checkpoint_count += 1
              now = monotonic_time

              if (now - last_progress_at) >= @progress_interval
                publish_progress(
                  completed: completed,
                  started_at: started_at,
                  now: now,
                  worker_thread_id: worker_thread_id
                )
                progress_event_count += 1
                last_progress_at = now
              end

              if (now - last_yield_at) >= @yield_interval
                Thread.pass
                yield_count += 1
                last_yield_at = monotonic_time
              end

              @cancellation_token.cancelled?
            end

            @total.times do |index|
              break if checkpoint.call

              checksum, cancelled = perform_pure_ruby_work(checksum, index, &checkpoint)
              break if cancelled

              completed = index + 1
              now = monotonic_time
              if completed == @total || (now - last_progress_at) >= @progress_interval
                publish_progress(
                  completed: completed,
                  started_at: started_at,
                  now: now,
                  worker_thread_id: worker_thread_id
                )
                progress_event_count += 1
                last_progress_at = now
              end
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
              worker_thread_id: worker_thread_id,
              yield_count: yield_count,
              checkpoint_count: checkpoint_count,
              progress_event_count: progress_event_count
            )
          rescue StandardError => e
            @mailbox.publish(
              type: :failed,
              error_class: e.class.name,
              error_message: e.message,
              worker_thread_id: Thread.current.object_id
            )
          end

          def publish_progress(completed:, started_at:, now:, worker_thread_id:)
            @mailbox.publish(
              type: :progress,
              total: @total,
              completed: completed,
              percent: completed.fdiv(@total) * 100.0,
              elapsed: now - started_at,
              worker_thread_id: worker_thread_id
            )
          end

          def perform_pure_ruby_work(seed, item_index)
            value = (seed ^ item_index) & 0xFFFF_FFFF
            @work_per_item.times do |iteration|
              value = ((value * 1_664_525) + 1_013_904_223 + iteration) & 0xFFFF_FFFF
              next unless ((iteration + 1) % @checkpoint_iterations).zero?

              return [value, true] if yield
            end
            [value, false]
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end
    end
  end
end
