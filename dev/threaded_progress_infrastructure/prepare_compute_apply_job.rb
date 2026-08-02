# frozen_string_literal: true

require_relative 'main_thread_slice_runner'
require_relative 'staged_compute_worker'
require_relative 'staged_job_contract'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class PrepareComputeApplyJob
          attr_reader :phase

          def initialize(
            prepare_total:,
            prepare_step:,
            compute_step:,
            apply_step:,
            rollback_step: nil,
            finalize_step: nil,
            slice_budget_ms: 8.0,
            max_items_per_slice: 100,
            weights: StagedJobContract::DEFAULT_WEIGHTS
          )
            raise ArgumentError, 'prepare_step must respond to call' unless prepare_step.respond_to?(:call)
            raise ArgumentError, 'compute_step must respond to call' unless compute_step.respond_to?(:call)
            raise ArgumentError, 'apply_step must respond to call' unless apply_step.respond_to?(:call)

            @main_thread = Thread.current
            @prepare_total = [prepare_total.to_i, 0].max
            @prepare_step = prepare_step
            @compute_step = compute_step
            @apply_step = apply_step
            @rollback_step = rollback_step
            @finalize_step = finalize_step
            @slice_budget_ms = slice_budget_ms.to_f
            @max_items_per_slice = max_items_per_slice.to_i
            @contract = StagedJobContract.new(weights: weights)
            reset_state
          end

          def start
            assert_main_thread!
            return snapshot unless @phase == :idle

            @started_at = monotonic_time
            transition_to!(:prepare)
            @prepared = Array.new(@prepare_total)
            @prepare_runner = MainThreadSliceRunner.new(
              total: @prepare_total,
              slice_budget_ms: @slice_budget_ms,
              max_items_per_slice: @max_items_per_slice
            ) do |index|
              @prepared[index] = deep_freeze(@prepare_step.call(index))
              index
            end
            @prepare_runner.start
            update_from_prepare_snapshot(@prepare_runner.snapshot)
            snapshot
          end

          def tick
            assert_main_thread!
            start if @phase == :idle
            return snapshot if terminal?

            case @phase
            when :prepare then tick_prepare
            when :compute then tick_compute
            when :apply then tick_apply
            when :finalize then tick_finalize
            end
            snapshot
          rescue StandardError => e
            fail_job(e)
            snapshot
          end

          def cancel!
            @cancel_requested = true
            @prepare_runner&.cancel! if @phase == :prepare
            @compute_cancellation_token&.cancel! if @phase == :compute
            true
          end

          def running?
            !terminal? && @phase != :idle
          end

          def terminal?
            StagedJobContract::TERMINAL_TYPES.include?(@type)
          end

          def worker_alive?
            @compute_worker&.alive? == true
          end

          def snapshot
            current_time = @finished_at || monotonic_time
            elapsed = @started_at ? current_time - @started_at : 0.0
            {
              type: @type,
              phase: @phase,
              terminal: terminal?,
              cancel_requested: @cancel_requested,
              phase_total: @phase_total,
              phase_completed: @phase_completed,
              phase_percent: @phase_percent,
              overall_percent: @overall_percent,
              elapsed: elapsed,
              prepare_count: @prepared&.compact&.length.to_i,
              compute_count: @computed&.length.to_i,
              apply_result: @apply_result,
              finalize_result: @finalize_result,
              rollback_attempted: @rollback_attempted,
              rollback_result: @rollback_result,
              worker_thread_id: @worker_thread_id,
              worker_alive: worker_alive?,
              prepare_slice_count: @prepare_snapshot[:slice_count],
              prepare_max_slice_ms: @prepare_snapshot[:max_slice_ms],
              prepare_overrun_count: @prepare_snapshot[:overrun_count],
              error_class: @error_class,
              error_message: @error_message
            }.freeze
          end

          private

          def reset_state
            @phase = :idle
            @type = :idle
            @started_at = nil
            @finished_at = nil
            @cancel_requested = false
            @prepared = nil
            @computed = nil
            @prepare_runner = nil
            @prepare_snapshot = {}
            @mailbox = nil
            @compute_cancellation_token = nil
            @compute_worker = nil
            @worker_thread_id = nil
            @phase_total = 0
            @phase_completed = 0
            @phase_percent = 0.0
            @overall_percent = 0.0
            @apply_result = nil
            @finalize_result = nil
            @rollback_attempted = false
            @rollback_result = nil
            @error_class = nil
            @error_message = nil
          end

          def tick_prepare
            prepare_snapshot = @prepare_runner.tick
            update_from_prepare_snapshot(prepare_snapshot)
            return unless prepare_snapshot[:terminal]

            case prepare_snapshot[:type]
            when :completed
              if @cancel_requested
                finish!(:cancelled)
              else
                @prepared = @prepared.freeze
                start_compute
              end
            when :cancelled
              finish!(:cancelled)
            when :failed
              raise RuntimeError, prepare_snapshot[:error_message].to_s
            end
          end

          def start_compute
            transition_to!(:compute)
            @phase_total = @prepared.length
            @phase_completed = 0
            @phase_percent = @phase_total.zero? ? 100.0 : 0.0
            update_overall_percent
            @mailbox = ProgressMailbox.new
            @compute_cancellation_token = CancellationToken.new
            @compute_worker = StagedComputeWorker.new(
              inputs: @prepared,
              mailbox: @mailbox,
              cancellation_token: @compute_cancellation_token,
              &@compute_step
            )
            @compute_worker.start
          end

          def tick_compute
            @compute_cancellation_token.cancel! if @cancel_requested
            events = @mailbox&.drain || []
            return if events.empty?

            event = reduce_compute_events(events)
            @worker_thread_id = event[:worker_thread_id] if event[:worker_thread_id]
            @phase_total = event[:total].to_i if event.key?(:total)
            @phase_completed = event[:completed].to_i if event.key?(:completed)
            @phase_percent = clamp_percent(event[:percent]) if event.key?(:percent)
            update_overall_percent
            return unless StagedJobContract::TERMINAL_TYPES.include?(event[:type].to_sym)

            case event[:type].to_sym
            when :completed
              @compute_worker.join(0.25)
              raise 'compute worker did not terminate after completion event' if @compute_worker.alive?

              @computed = @compute_worker.results
              if @cancel_requested
                finish!(:cancelled)
              else
                transition_to!(:apply)
                @phase_total = 1
                @phase_completed = 0
                @phase_percent = 0.0
                update_overall_percent
              end
            when :cancelled
              finish!(:cancelled)
            when :failed
              error_class = event[:error_class].to_s
              error_message = event[:error_message].to_s
              raise RuntimeError, [error_class, error_message].reject(&:empty?).join(': ')
            end
          end

          def tick_apply
            if @cancel_requested
              finish!(:cancelled)
              return
            end

            @apply_result = @apply_step.call(@computed)
            @phase_completed = 1
            @phase_percent = 100.0
            update_overall_percent
            transition_to!(:finalize)
            @phase_total = 1
            @phase_completed = 0
            @phase_percent = 0.0
            update_overall_percent
          rescue StandardError => e
            attempt_rollback(e)
            raise
          end

          def tick_finalize
            @finalize_result = @finalize_step&.call(@apply_result, @computed)
            @phase_completed = 1
            @phase_percent = 100.0
            update_overall_percent
            finish!(:completed)
          end

          def attempt_rollback(error)
            return unless @rollback_step

            @rollback_attempted = true
            @rollback_result = @rollback_step.call(error, @apply_result, @computed)
          rescue StandardError => rollback_error
            @rollback_result = {
              type: :rollback_failed,
              error_class: rollback_error.class.name,
              error_message: rollback_error.message
            }.freeze
          end

          def fail_job(error)
            @error_class = error.class.name
            @error_message = error.message
            finish!(:failed)
          end

          def finish!(type)
            transition_to!(type)
            @type = type
            @finished_at = monotonic_time
            @overall_percent = 100.0 if type == :completed
          end

          def transition_to!(next_phase)
            @contract.assert_transition!(from: @phase, to: next_phase)
            @phase = next_phase
            @type = StagedJobContract::TERMINAL_TYPES.include?(next_phase) ? next_phase : :running
          end

          def update_from_prepare_snapshot(prepare_snapshot)
            @prepare_snapshot = prepare_snapshot
            @phase_total = prepare_snapshot[:total].to_i
            @phase_completed = prepare_snapshot[:completed].to_i
            @phase_percent = clamp_percent(prepare_snapshot[:percent])
            update_overall_percent
          end

          def update_overall_percent
            @overall_percent = @contract.overall_percent(
              phase: @phase,
              phase_percent: @phase_percent
            )
          end

          def reduce_compute_events(events)
            terminal = events.reverse.find do |event|
              StagedJobContract::TERMINAL_TYPES.include?(event[:type].to_sym)
            end
            terminal || events.last
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

          def clamp_percent(value)
            [[value.to_f, 0.0].max, 100.0].min
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def assert_main_thread!
            return if Thread.current.equal?(@main_thread)

            raise "staged job main-thread method called from thread #{Thread.current.object_id}"
          end
        end
      end
    end
  end
end
