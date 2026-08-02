# frozen_string_literal: true

require_relative 'main_thread_slice_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class BulkCellSpaceConversionPreflightSession
          STAGES = %i[prepare geometry target].freeze
          TERMINAL_TYPES = %i[completed cancelled failed].freeze
          STAGE_WEIGHTS = {
            prepare: 0.34,
            geometry: 0.33,
            target: 0.33
          }.freeze

          def initialize(
            jobs:,
            adapter:,
            slice_budget_ms: 8.0,
            max_items_per_slice: 50,
            predictive_budget: true
          )
            @main_thread = Thread.current
            @jobs = Array(jobs).freeze
            @adapter = adapter
            @slice_budget_ms = slice_budget_ms.to_f
            @max_items_per_slice = max_items_per_slice.to_i
            @predictive_budget = predictive_budget == true
            reset_state
          end

          def start
            assert_main_thread!
            return snapshot unless @type == :idle

            @started_at = monotonic_time
            start_stage(:prepare, @jobs)
            snapshot
          end

          def tick
            assert_main_thread!
            start if @type == :idle
            return snapshot if terminal?

            runner_snapshot = @runner.tick
            @runner_snapshot = runner_snapshot
            update_progress(runner_snapshot)
            return snapshot unless runner_snapshot[:terminal]

            case runner_snapshot[:type]
            when :completed
              finish_stage
            when :cancelled
              finish!(:cancelled)
            when :failed
              fail!(runner_snapshot[:error_class], runner_snapshot[:error_message])
            end
            snapshot
          rescue StandardError => e
            fail!(e.class.name, e.message)
            snapshot
          end

          def cancel!
            assert_main_thread!
            @cancel_requested = true
            @runner&.cancel!
            true
          end

          def running?
            @type == :running
          end

          def terminal?
            TERMINAL_TYPES.include?(@type)
          end

          def plan
            return nil unless terminal?

            @plan
          end

          def errors
            combined_errors.freeze
          end

          def snapshot
            current_time = @finished_at || monotonic_time
            elapsed = @started_at ? current_time - @started_at : 0.0
            {
              type: @type,
              stage: @stage,
              terminal: terminal?,
              cancel_requested: @cancel_requested,
              total_jobs: @jobs.length,
              stage_total: @stage_total,
              stage_completed: @stage_completed,
              stage_percent: @stage_percent,
              overall_percent: @overall_percent,
              current_plan_count: @stage_input.length,
              plan_count: @plan&.length.to_i,
              error_count: combined_errors.length,
              preparation_error_count: @stage_errors[:prepare].length,
              geometry_error_count: @stage_errors[:geometry].length,
              target_error_count: @stage_errors[:target].length,
              slice_count: @runner_snapshot[:slice_count].to_i,
              last_slice_items: @runner_snapshot[:last_slice_items].to_i,
              max_slice_items: @runner_snapshot[:max_slice_items].to_i,
              max_slice_ms: @runner_snapshot[:max_slice_ms].to_f,
              overrun_count: @runner_snapshot[:overrun_count].to_i,
              predictive_budget: @runner_snapshot[:predictive_budget] == true,
              predictive_stop_count: @runner_snapshot[:predictive_stop_count].to_i,
              estimated_item_ms: @runner_snapshot[:estimated_item_ms].to_f,
              max_item_ms: @runner_snapshot[:max_item_ms].to_f,
              elapsed: elapsed,
              main_thread_id: @main_thread.object_id,
              current_thread_id: Thread.current.object_id,
              error_class: @error_class,
              error_message: @error_message
            }.freeze
          end

          private

          def reset_state
            @type = :idle
            @stage = nil
            @started_at = nil
            @finished_at = nil
            @cancel_requested = false
            @stage_input = [].freeze
            @stage_output = []
            @stage_errors = {
              prepare: [],
              geometry: [],
              target: []
            }
            @runner = nil
            @runner_snapshot = {}
            @stage_total = 0
            @stage_completed = 0
            @stage_percent = 0.0
            @overall_percent = 0.0
            @plan = nil
            @error_class = nil
            @error_message = nil
          end

          def start_stage(stage, input)
            @stage = stage
            @type = :running
            @stage_input = Array(input).freeze
            @stage_output = Array.new(@stage_input.length)
            @runner = MainThreadSliceRunner.new(
              total: @stage_input.length,
              slice_budget_ms: @slice_budget_ms,
              max_items_per_slice: @max_items_per_slice,
              predictive_budget: @predictive_budget
            ) do |index|
              process_stage_item(index)
              index
            end
            @runner.start
            @runner_snapshot = @runner.snapshot
            update_progress(@runner_snapshot)
          end

          def process_stage_item(index)
            assert_main_thread!
            item = @stage_input.fetch(index)
            output, error = case @stage
                            when :prepare
                              @adapter.prepare(item, index)
                            when :geometry
                              @adapter.validate_geometry(item)
                            when :target
                              @adapter.validate_target(item)
                            else
                              raise "unsupported preflight stage: #{@stage}"
                            end
            @stage_output[index] = output
            @stage_errors.fetch(@stage) << error if error
            true
          end

          def finish_stage
            if @cancel_requested
              finish!(:cancelled)
              return
            end

            filtered = @stage_output.compact.freeze
            case @stage
            when :prepare
              if filtered.empty? && @stage_errors[:prepare].empty?
                @stage_errors[:prepare] << @adapter.empty_plan_error
              end
              start_stage(:geometry, filtered)
            when :geometry
              start_stage(:target, filtered)
            when :target
              @plan = filtered
              finish!(:completed)
            end
          end

          def update_progress(runner_snapshot)
            @stage_total = runner_snapshot[:total].to_i
            @stage_completed = runner_snapshot[:completed].to_i
            @stage_percent = clamp_percent(runner_snapshot[:percent])
            @overall_percent = weighted_overall_percent(@stage, @stage_percent)
          end

          def weighted_overall_percent(stage, stage_percent)
            return 100.0 if stage == :completed
            return 0.0 unless STAGES.include?(stage)

            offset = 0.0
            STAGES.each do |candidate|
              break if candidate == stage

              offset += STAGE_WEIGHTS.fetch(candidate)
            end
            weight = STAGE_WEIGHTS.fetch(stage)
            clamp_percent((offset + (weight * stage_percent.fdiv(100.0))) * 100.0)
          end

          def finish!(type)
            @type = type
            @stage = type
            @finished_at = monotonic_time
            @overall_percent = 100.0 if type == :completed
          end

          def fail!(error_class, error_message)
            @error_class = error_class.to_s
            @error_message = error_message.to_s
            finish!(:failed)
          end

          def combined_errors
            STAGES.flat_map { |stage| @stage_errors.fetch(stage) }
          end

          def clamp_percent(value)
            [[value.to_f, 0.0].max, 100.0].min
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def assert_main_thread!
            return if Thread.current.equal?(@main_thread)

            raise "CellSpace preflight session called outside main thread: #{Thread.current.object_id}"
          end
        end
      end
    end
  end
end
