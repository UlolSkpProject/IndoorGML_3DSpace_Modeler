# frozen_string_literal: true

require_relative 'cell_space_conversion_preflight_prototype'
require_relative 'cell_space_conversion_apply_policy'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        class Controller
          unless method_defined?(:start_job_without_progress_apply)
            alias_method :start_job_without_progress_apply, :start_job
          end
          unless method_defined?(:status_without_progress_apply)
            alias_method :status_without_progress_apply, :status
          end
          unless method_defined?(:verify_without_progress_apply)
            alias_method :verify_without_progress_apply, :verify
          end
          unless method_defined?(:cancel_job_without_progress_apply)
            alias_method :cancel_job_without_progress_apply, :cancel_job
          end
          unless method_defined?(:close_without_progress_apply)
            alias_method :close_without_progress_apply, :close
          end
          unless private_method_defined?(:pump_without_progress_apply)
            alias_method :pump_without_progress_apply, :pump
          end

          def start_apply_job(
            fallback_cell_type: CellSpaceType::GENERAL,
            fallback_category_code: nil,
            slice_budget_ms: 8.0,
            max_items_per_slice: 25,
            max_apply_jobs: ThreadedProgressInfrastructure::CellSpaceConversionApplyPolicy::DEFAULT_MAX_APPLY_JOBS
          )
            assert_main_thread!
            return false if @session&.running?

            model = Sketchup.active_model
            indoor_model = IndoorModel.current
            path_controller = ActivePathController.new(model, logger: IndoorCore::Logger)
            initial_active_path = path_controller.snapshot
            before_counts = feature_counts(indoor_model)

            unless indoor_model.prepare_cell_space_creation_active_context(model)
              raise 'Failed to prepare active context for CellSpace conversion'
            end
            conversion_active_path = path_controller.snapshot

            started = start_job_without_progress_apply(
              fallback_cell_type: fallback_cell_type,
              fallback_category_code: fallback_category_code,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice
            )
            unless started
              restore_active_path_snapshot(indoor_model, model, initial_active_path)
              return false
            end

            @apply_mode = true
            @apply_phase = :preflight
            @preflight_handled = false
            @apply_policy = ThreadedProgressInfrastructure::CellSpaceConversionApplyPolicy.new(
              max_apply_jobs: max_apply_jobs
            )
            @indoor_model = indoor_model
            @initial_active_path = initial_active_path
            @conversion_active_path = conversion_active_path
            @before_feature_counts = before_counts.freeze
            @after_feature_counts = nil
            @apply_result = nil
            @apply_elapsed = nil
            @apply_error_class = nil
            @apply_error_message = nil
            @apply_decision = nil

            if @jobs.length > @apply_policy.max_apply_jobs
              block_apply_before_preflight(:job_limit_exceeded)
              return false
            end

            true
          rescue StandardError => e
            puts "[CELLSPACE PROGRESS APPLY] start failed: #{e.class}: #{e.message}"
            restore_active_path_snapshot(indoor_model, model, initial_active_path) if indoor_model && model
            false
          end

          def status
            base = status_without_progress_apply
            result = @apply_result
            snapshot = base.merge(
              apply_mode: @apply_mode == true,
              apply_phase: @apply_phase,
              max_apply_jobs: @apply_policy&.max_apply_jobs,
              apply_decision: @apply_decision&.reason,
              converted_count: result ? result.converted_count.to_i : 0,
              apply_error_count: result ? Array(result.errors).length : 0,
              apply_errors: result ? Array(result.errors) : [],
              apply_elapsed: @apply_elapsed,
              apply_error_class: @apply_error_class,
              apply_error_message: @apply_error_message,
              feature_counts_before: @before_feature_counts,
              feature_counts_after: @after_feature_counts
            ).freeze
            puts "[CELLSPACE PROGRESS APPLY] #{snapshot.inspect}"
            snapshot
          end

          def verify_apply(expected = :converted)
            assert_main_thread!
            expected = expected.to_sym
            current = feature_counts(@indoor_model || IndoorModel.current)
            converted = @apply_result ? @apply_result.converted_count.to_i : 0
            passed = case expected
                     when :converted
                       converted.positive? &&
                         @before_feature_counts &&
                         current[:cell_spaces] == @before_feature_counts[:cell_spaces] + converted &&
                         current[:states] == @before_feature_counts[:states] + converted
                     when :undone
                       @before_feature_counts && current == @before_feature_counts
                     when :redone
                       @after_feature_counts && current == @after_feature_counts
                     when :not_applied
                       @before_feature_counts && current == @before_feature_counts
                     else
                       raise ArgumentError, "unsupported expected state: #{expected}"
                     end
            payload = {
              expected: expected,
              converted_count: converted,
              feature_counts_before: @before_feature_counts,
              feature_counts_after_apply: @after_feature_counts,
              feature_counts_current: current,
              passed: passed
            }.freeze
            puts "[CELLSPACE PROGRESS APPLY VERIFY] #{payload.inspect}"
            payload
          end

          def undo_apply
            assert_main_thread!
            Sketchup.send_action('editUndo:')
            invalidate_view
            true
          end

          def redo_apply
            assert_main_thread!
            Sketchup.send_action('editRedo:')
            invalidate_view
            true
          end

          def cancel_job
            assert_main_thread!
            if @apply_mode && %i[awaiting_confirmation apply_pending].include?(@apply_phase)
              @apply_phase = :cancelled
              stop_timer
              restore_initial_active_path
              @state.apply(
                type: :cancelled,
                total: 1,
                completed: 0,
                percent: 100.0,
                message: 'CellSpace 실제 적용이 취소되었습니다.'
              )
              invalidate_view
              schedule_hide
              return true
            end

            cancel_job_without_progress_apply
          end

          def close
            assert_main_thread!
            restore_initial_active_path if @apply_mode && !%i[completed failed].include?(@apply_phase)
            close_without_progress_apply
          end

          private

          def pump
            result = pump_without_progress_apply
            handle_preflight_terminal if @apply_mode && !@preflight_handled && @session&.terminal?
            result
          end

          def handle_preflight_terminal
            @preflight_handled = true
            stop_hide_timer
            snapshot = @session.snapshot
            plan = @session.plan
            @apply_decision = @apply_policy.evaluate(
              preflight_type: snapshot[:type],
              job_count: @jobs.length,
              plan_count: plan ? plan.length : 0,
              error_count: @session.errors.length
            )

            unless @apply_decision.allowed?
              @apply_phase = :blocked
              restore_initial_active_path
              @state.apply(
                type: :cancelled,
                total: @jobs.length,
                completed: snapshot[:stage_completed],
                percent: snapshot[:overall_percent],
                message: "실제 적용 차단: #{@apply_decision.reason}"
              )
              invalidate_view
              schedule_hide
              return
            end

            @apply_phase = :awaiting_confirmation
            @state.apply(
              type: :progress,
              total: 1,
              completed: 0,
              percent: 90.0,
              message: "사전검사 통과: #{@jobs.length}개. 실제 CellSpace 변환 승인 대기"
            )
            invalidate_view

            answer = UI.messagebox(
              "사전검사를 통과한 #{@jobs.length}개 Solid를 실제 CellSpace로 변환합니다.\n\n" \
              "기존 production 변환 경로와 단일 Undo operation을 사용합니다.\n" \
              "계속하시겠습니까?",
              MB_YESNO
            )
            if answer == IDYES
              schedule_apply
            else
              @apply_phase = :cancelled
              restore_initial_active_path
              @state.apply(
                type: :cancelled,
                total: 1,
                completed: 0,
                percent: 100.0,
                message: '사용자가 실제 CellSpace 변환을 취소했습니다.'
              )
              invalidate_view
              schedule_hide
            end
          end

          def schedule_apply
            @apply_phase = :apply_pending
            @state.apply(
              type: :progress,
              total: 1,
              completed: 0,
              percent: 95.0,
              message: '기존 production 변환 경로 적용 준비 중'
            )
            invalidate_view
            stop_timer
            @timer_id = UI.start_timer(0.05, false) do
              @timer_id = nil
              perform_apply
              false
            end
          end

          def perform_apply
            assert_main_thread!
            unless Sketchup.active_model.equal?(@job_model)
              raise '실제 적용 전에 활성 모델이 변경되었습니다.'
            end

            @apply_phase = :apply
            @state.apply(
              type: :progress,
              total: 1,
              completed: 0,
              percent: 97.0,
              message: '기존 production CellSpace 변환 operation 실행 중'
            )
            invalidate_view
            started_at = monotonic_time
            @apply_result = @indoor_model.convert_cell_space_jobs_bulk(
              @jobs,
              fallback_target: @fallback_target,
              original_active_path: @conversion_active_path,
              operation_name: '[DEV] Progress CellSpace Conversion',
              activate_root_context: true
            )
            @apply_elapsed = monotonic_time - started_at
            @after_feature_counts = feature_counts(@indoor_model).freeze

            if @apply_result.converted_count.to_i == @jobs.length && Array(@apply_result.errors).empty?
              @apply_phase = :completed
              @state.apply(
                type: :completed,
                total: @jobs.length,
                completed: @apply_result.converted_count,
                percent: 100.0,
                message: "CellSpace 실제 변환 완료: #{@apply_result.converted_count}개"
              )
            else
              @apply_phase = :failed
              @state.apply(
                type: :failed,
                total: @jobs.length,
                completed: @apply_result.converted_count,
                percent: 100.0,
                error_message: "일부 또는 전체 변환 실패: #{Array(@apply_result.errors).length}개 오류"
              )
            end
            invalidate_view
            schedule_hide
            true
          rescue StandardError => e
            @apply_elapsed = monotonic_time - started_at if defined?(started_at) && started_at
            @apply_phase = :failed
            @apply_error_class = e.class.name
            @apply_error_message = e.message
            @after_feature_counts = feature_counts(@indoor_model).freeze if @indoor_model
            restore_initial_active_path
            @state.apply(
              type: :failed,
              total: @jobs.length,
              completed: 0,
              percent: 100.0,
              error_message: "#{e.class}: #{e.message}"
            )
            puts "[CELLSPACE PROGRESS APPLY] failed: #{e.class}: #{e.message}"
            invalidate_view
            schedule_hide
            false
          end

          def block_apply_before_preflight(reason)
            @apply_decision = ThreadedProgressInfrastructure::CellSpaceConversionApplyPolicy::Decision.new(
              allowed: false,
              reason: reason
            ).freeze
            @apply_phase = :blocked
            @preflight_handled = true
            @session&.cancel!
            @session&.tick
            stop_timer
            restore_initial_active_path
            @state.apply(
              type: :cancelled,
              total: @jobs.length,
              completed: 0,
              percent: 0.0,
              message: "실제 적용 차단: 작업 #{@jobs.length}개가 안전 제한 #{@apply_policy.max_apply_jobs}개를 초과"
            )
            invalidate_view
            schedule_hide
          end

          def feature_counts(indoor_model)
            {
              cell_spaces: valid_feature_count(indoor_model&.cell_spaces),
              states: valid_feature_count(indoor_model&.states),
              transitions: valid_feature_count(indoor_model&.transitions)
            }.freeze
          end

          def valid_feature_count(collection)
            Array(collection).count { |feature| feature&.valid? }
          rescue StandardError
            0
          end

          def restore_initial_active_path
            return true unless @indoor_model && @job_model

            restore_active_path_snapshot(@indoor_model, @job_model, @initial_active_path)
          end

          def restore_active_path_snapshot(indoor_model, model, snapshot)
            controller = ActivePathController.new(model, logger: IndoorCore::Logger)
            indoor_model.with_active_path_enforcement_suspended do
              controller.restore(snapshot, close_when_nil: true)
            end
          rescue StandardError => e
            puts "[CELLSPACE PROGRESS APPLY] active path restore failed: #{e.class}: #{e.message}"
            false
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end

        class << self
          def start_apply!(**options)
            controller.start_apply_job(**options)
          end

          def verify_apply!(expected = :converted)
            controller.verify_apply(expected)
          end

          def undo_apply!
            controller.undo_apply
          end

          def redo_apply!
            controller.redo_apply
          end
        end
      end
    end
  end
end

puts '[CELLSPACE CONVERSION PROGRESS APPLY PATCH] installed'
puts 'Start : ...::CellSpaceConversionPreflightPrototype.start_apply!'
puts 'Status: ...::CellSpaceConversionPreflightPrototype.status!'
puts 'Verify: ...::CellSpaceConversionPreflightPrototype.verify_apply!(:converted)'
puts 'Undo  : ...::CellSpaceConversionPreflightPrototype.undo_apply!'
puts 'Redo  : ...::CellSpaceConversionPreflightPrototype.redo_apply!'
