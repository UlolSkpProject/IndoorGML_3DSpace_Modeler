# frozen_string_literal: true

require_relative 'main_thread_slice_runner'
require_relative 'staged_job_contract'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class PrepareComputeApplyJob
          COMPUTE_EXECUTION = :main_thread_sliced

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
            compute_slice_budget_ms: nil,
            compute_max_items_per_slice: nil,
            compute_predictive_budget: true,
            compute_prediction_safety_factor: 1.0,
            compute_budget_guard_ms: 0.25,
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
            @prepare_slice_budget_ms = slice_budget_ms.to_f
            @prepare_max_items_per_slice = max_items_per_slice.to_i
            @compute_slice_budget_ms = (
              compute_slice_budget_ms.nil? ? slice_budget_ms : compute_slice_budget_ms
            ).to_f
            @compute_max_items_per_slice = (
              compute_max_items_per_slice.nil? ? max_items_per_slice : compute_max_items_per_slice
            ).to_i
            @compute_predictive_budget = compute_predictive_budget == true
            @compute_prediction_safety_factor = [compute_prediction_safety_factor.to_f, 0.0].max
            @compute_budget_guard_ms = [compute_budget_guard_ms.to_f, 0.0].max
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
              slice_budget_ms: @prepare_slice_budget_ms,
              max_items_per_slice: @prepare_max_items_per_slice
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
            @compute_runner&.cancel! if @phase == :compute
            true
          end

          def running?
            !terminal? && @phase != :idle
          end

          def terminal?
            StagedJobContract::TERMINAL_TYPES.include?(@type)
          end

          # Retained for status compatibility. CPU-bound compute no longer runs in a Ruby worker.
          def worker_alive?
            false
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
              prepare_count: @prepare_snapshot[:completed].to_i,
              compute_count: @compute_snapshot[:completed].to_i,
              apply_result: @apply_result,
              finalize_result: @finalize_result,
              rollback_attempted: @rollback_attempted,
              rollback_result: @rollback_result,
              compute_execution: COMPUTE_EXECUTION,
              compute_thread_id: @compute_thread_id,
              worker_thread_id: nil,
              worker_alive: false,
              prepare_slice_count: @prepare_snapshot[:slice_count],
              prepare_last_slice_items: @prepare_snapshot[:last_slice_items],
              prepare_max_slice_ms: @prepare_snapshot[:max_slice_ms],
              prepare_overrun_count: @prepare_snapshot[:overrun_count],
              compute_predictive_budget: @compute_snapshot[:predictive_budget],
              compute_prediction_safety_factor: @compute_snapshot[:prediction_safety_factor],
              compute_budget_guard_ms: @compute_snapshot[:budget_guard_ms],
              compute_estimated_item_ms: @compute_snapshot[:estimated_item_ms],
              compute_last_item_ms: @compute_snapshot[:last_item_ms],
              compute_max_item_ms: @compute_snapshot[:max_item_ms],
              compute_predictive_stop_count: @compute_snapshot[:predictive_stop_count],
              compute_slice_count: @compute_snapshot[:slice_count],
              compute_last_slice_items: @compute_snapshot[:last_slice_items],
              compute_max_slice_items: @compute_snapshot[:max_slice_items],
              compute_max_slice_ms: @compute_snapshot[:max_slice_ms],
              compute_overrun_count: @compute_snapshot[:overrun_count],
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
            @compute_runner = nil
            @compute_snapshot = {}
            @compute_thread_id = nil
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
            @computed = Array.new(@prepared.length)
            @compute_runner = MainThreadSliceRunner.new(
              total: @prepared.length,
              slice_budget_ms: @compute_slice_budget_ms,
              max_items_per_slice: @compute_max_items_per_slice,
              predictive_budget: @compute_predictive_budget,
              prediction_safety_factor: @compute_prediction_safety_factor,
              budget_guard_ms: @compute_budget_guard_ms
            ) do |index|
              assert_main_thread!
              @compute_thread_id ||= Thread.current.object_id
              @computed[index] = deep_freeze(@compute_step.call(@prepared[index], index))
              index
            end
            @compute_runner.start
            update_from_compute_snapshot(@compute_runner.snapshot)
          end

          def tick_compute
            compute_snapshot = @compute_runner.tick
            update_from_compute_snapshot(compute_snapshot)
            return unless compute_snapshot[:terminal]

            case compute_snapshot[:type]
            when :completed
              if @cancel_requested
                finish!(:cancelled)
              else
                @computed = @computed.freeze
                transition_to!(:apply)
                @phase_total = 1
                @phase_completed = 0
                @phase_percent = 0.0
                update_overall_percent
              end
            when :cancelled
              finish!(:cancelled)
            when :failed
              raise RuntimeError, compute_snapshot[:error_message].to_s
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
            update_phase_from_runner_snapshot(prepare_snapshot)
          end

          def update_from_compute_snapshot(compute_snapshot)
            @compute_snapshot = compute_snapshot
            update_phase_from_runner_snapshot(compute_snapshot)
          end

          def update_phase_from_runner_snapshot(runner_snapshot)
            @phase_total = runner_snapshot[:total].to_i
            @phase_completed = runner_snapshot[:completed].to_i
            @phase_percent = clamp_percent(runner_snapshot[:percent])
            update_overall_percent
          end

          def update_overall_percent
            @overall_percent = @contract.overall_percent(
              phase: @phase,
              phase_percent: @phase_percent
            )
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
