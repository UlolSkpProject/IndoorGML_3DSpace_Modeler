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
            current_item_iteration = 0
            last_progress_at = started_at
            last_yield_at = started_at
            yield_count = 0
            checkpoint_count = 0
            progress_event_count = 0

            @mailbox.publish(
              type: :started,
              total: @total,
              completed: 0,
              current_item: 1,
              current_item_percent: 0.0,
              effective_completed: 0.0,
              percent: 0.0,
              elapsed: 0.0,
              worker_thread_id: worker_thread_id
            )

            checkpoint = lambda do |item_iteration|
              checkpoint_count += 1
              current_item_iteration = item_iteration
              now = monotonic_time

              if (now - last_progress_at) >= @progress_interval
                publish_progress(
                  completed: completed,
                  item_iteration: current_item_iteration,
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
              current_item_iteration = 0
              break if checkpoint.call(0)

              checksum, cancelled, current_item_iteration = perform_pure_ruby_work(
                checksum,
                index,
                &checkpoint
              )
              break if cancelled

              completed = index + 1
              current_item_iteration = completed == @total ? @work_per_item : 0
              now = monotonic_time
              if completed == @total || (now - last_progress_at) >= @progress_interval
                publish_progress(
                  completed: completed,
                  item_iteration: current_item_iteration,
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
            terminal_progress = progress_metrics(
              completed: completed,
              item_iteration: current_item_iteration
            )
            @mailbox.publish(
              terminal_progress.merge(
                type: terminal_type,
                total: @total,
                elapsed: finished_at - started_at,
                checksum: checksum,
                worker_thread_id: worker_thread_id,
                yield_count: yield_count,
                checkpoint_count: checkpoint_count,
                progress_event_count: progress_event_count
              )
            )
          rescue StandardError => e
            @mailbox.publish(
              type: :failed,
              error_class: e.class.name,
              error_message: e.message,
              worker_thread_id: Thread.current.object_id
            )
          end

          def publish_progress(completed:, item_iteration:, started_at:, now:, worker_thread_id:)
            @mailbox.publish(
              progress_metrics(
                completed: completed,
                item_iteration: item_iteration
              ).merge(
                type: :progress,
                total: @total,
                elapsed: now - started_at,
                worker_thread_id: worker_thread_id
              )
            )
          end

          def progress_metrics(completed:, item_iteration:)
            completed = [[completed.to_i, 0].max, @total].min
            if completed >= @total
              return {
                completed: @total,
                current_item: @total,
                current_item_percent: 100.0,
                effective_completed: @total.to_f,
                percent: 100.0
              }
            end

            iteration = [[item_iteration.to_i, 0].max, @work_per_item].min
            item_fraction = iteration.fdiv(@work_per_item)
            effective_completed = completed + item_fraction
            {
              completed: completed,
              current_item: completed + 1,
              current_item_percent: item_fraction * 100.0,
              effective_completed: effective_completed,
              percent: effective_completed.fdiv(@total) * 100.0
            }
          end

          def perform_pure_ruby_work(seed, item_index)
            value = (seed ^ item_index) & 0xFFFF_FFFF
            @work_per_item.times do |iteration|
              value = ((value * 1_664_525) + 1_013_904_223 + iteration) & 0xFFFF_FFFF
              item_iteration = iteration + 1
              next unless (item_iteration % @checkpoint_iterations).zero?

              return [value, true, item_iteration] if yield(item_iteration)
            end
            [value, false, @work_per_item]
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
      end
    end
  end
end
