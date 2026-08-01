# frozen_string_literal: true

require_relative 'read_only_api_slice_prototype'
require_relative 'read_only_work_plan'
require_relative 'overlay_semantics_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module MainThreadSlicePrototype
        DEFAULT_MODE = :single_pass unless const_defined?(:DEFAULT_MODE, false)
        DEFAULT_STRESS_ITERATIONS = 50_000 unless const_defined?(:DEFAULT_STRESS_ITERATIONS, false)

        class Controller
          def start_job(
            mode: MainThreadSlicePrototype::DEFAULT_MODE,
            stress_iterations: MainThreadSlicePrototype::DEFAULT_STRESS_ITERATIONS,
            slice_budget_ms: MainThreadSlicePrototype::DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: MainThreadSlicePrototype::DEFAULT_MAX_ITEMS_PER_SLICE
          )
            assert_main_thread!
            return false if @runner&.running?

            close_worker_prototype
            model = Sketchup.active_model
            return false unless ensure_registered(model)

            stop_timers
            @job_model = model
            @targets = collect_targets(model)
            if @targets.empty?
              @state.apply(type: :failed, error_message: '조회할 SketchUp entity가 없습니다.')
              invalidate_view
              schedule_hide
              return false
            end

            @work_plan = ThreadedProgressInfrastructure::ReadOnlyWorkPlan.new(
              mode: mode,
              target_count: @targets.length,
              stress_iterations: stress_iterations
            )
            @read_checksum = 0
            @state.reset!
            @runner = ThreadedProgressInfrastructure::MainThreadSliceRunner.new(
              total: @work_plan.total,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice
            ) do |work_index|
              target_index = @work_plan.target_index(work_index)
              inspect_entity(@targets[target_index], work_index)
            end
            @runner.start
            apply_runner_snapshot(@runner.snapshot)
            invalidate_view
            start_timer
            true
          rescue ArgumentError => e
            @state.apply(type: :failed, error_message: e.message)
            invalidate_view
            schedule_hide
            false
          end

          def status
            assert_main_thread!
            runner_snapshot = @runner&.snapshot || {}
            snapshot = @state.snapshot.merge(
              current_thread_id: Thread.current.object_id,
              main_thread_id: @main_thread.object_id,
              work_mode: @work_plan&.mode,
              work_description: @work_plan&.description,
              runner_type: runner_snapshot[:type],
              runner_terminal: runner_snapshot[:terminal],
              slice_budget_ms: runner_snapshot[:slice_budget_ms],
              slice_count: runner_snapshot[:slice_count],
              last_slice_items: runner_snapshot[:last_slice_items],
              last_slice_ms: runner_snapshot[:last_slice_ms],
              max_slice_ms: runner_snapshot[:max_slice_ms],
              overrun_count: runner_snapshot[:overrun_count],
              checksum: runner_snapshot[:checksum],
              target_count: @targets.length,
              timer_active: !@timer_id.nil?,
              overlay_valid: @overlay&.valid? == true,
              registered_model_id: @registered_model&.object_id
            )
            puts "[MAIN THREAD SLICE PROTOTYPE] #{snapshot.inspect}"
            snapshot
          end

          def close
            result = super
            @work_plan = nil
            result
          end

          private

          def apply_runner_snapshot(snapshot)
            type = snapshot[:type] == :running ? :progress : snapshot[:type]
            @state.apply(
              type: type,
              total: snapshot[:total],
              completed: snapshot[:completed],
              current_item: snapshot[:completed].to_i + 1,
              current_item_percent: 0.0,
              effective_completed: snapshot[:completed].to_f,
              percent: snapshot[:percent],
              elapsed: snapshot[:elapsed],
              message: message_for(snapshot[:type]),
              count_label: @work_plan&.count_label || '완료',
              show_current_item_progress: false,
              work_mode: @work_plan&.mode,
              slice_budget_ms: snapshot[:slice_budget_ms],
              slice_count: snapshot[:slice_count],
              last_slice_items: snapshot[:last_slice_items],
              last_slice_ms: snapshot[:last_slice_ms],
              max_slice_ms: snapshot[:max_slice_ms],
              overrun_count: snapshot[:overrun_count],
              read_checksum: @read_checksum
            )
          end

          def message_for(type)
            prefix = if @work_plan&.stress?
                       'SketchUp API 반복 부하 테스트'
                     else
                       'SketchUp Entity read-only 1회 순회'
                     end

            case type
            when :idle then "#{prefix} 대기"
            when :running then "#{prefix} 중 (대상 #{@targets.length}개)"
            when :completed then "#{prefix} 완료"
            when :cancelled then "#{prefix} 취소됨"
            when :failed then "#{prefix} 실패"
            else "#{prefix} 준비 중"
            end
          end
        end

        class << self
          def start!(
            mode: DEFAULT_MODE,
            stress_iterations: DEFAULT_STRESS_ITERATIONS,
            slice_budget_ms: DEFAULT_SLICE_BUDGET_MS,
            max_items_per_slice: DEFAULT_MAX_ITEMS_PER_SLICE
          )
            controller.start_job(
              mode: mode,
              stress_iterations: stress_iterations,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice
            )
          end
        end
      end
    end
  end
end

puts '[MAIN THREAD SLICE MODES PATCH] installed'
puts 'Single pass: ...::MainThreadSlicePrototype.start!'
puts 'Stress     : ...::MainThreadSlicePrototype.start!(mode: :stress, stress_iterations: 50_000)'
