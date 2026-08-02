# frozen_string_literal: true

require_relative 'cell_space_conversion_apply_history_guard_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionProgressApplyRunner
        TERMINAL_PHASES = %i[completed failed cancelled blocked].freeze

        class << self
          def run!(
            fallback_cell_type: CellSpaceType::GENERAL,
            fallback_category_code: nil,
            slice_budget_ms: 8.0,
            max_items_per_slice: 25,
            max_apply_jobs: ThreadedProgressInfrastructure::CellSpaceConversionApplyPolicy::DEFAULT_MAX_APPLY_JOBS
          )
            prototype.install!
            started = prototype.start_apply!(
              fallback_cell_type: fallback_cell_type,
              fallback_category_code: fallback_category_code,
              slice_budget_ms: slice_budget_ms,
              max_items_per_slice: max_items_per_slice,
              max_apply_jobs: max_apply_jobs
            )

            unless started
              puts '[CELLSPACE PROGRESS APPLY RUNNER] start blocked or failed'
              prototype.status!
              prototype.verify_apply!(:not_applied)
              return false
            end

            puts '[CELLSPACE PROGRESS APPLY RUNNER] started'
            puts '[CELLSPACE PROGRESS APPLY RUNNER] preflight 완료 후 실제 적용 확인창이 표시됩니다.'
            schedule_terminal_report
            true
          rescue StandardError => e
            puts "[CELLSPACE PROGRESS APPLY RUNNER] failed: #{e.class}: #{e.message}"
            false
          end

          def status!
            prototype.status!
          end

          def verify!(expected = :converted)
            prototype.verify_apply!(expected)
          end

          def undo!
            prototype.undo_apply!
          end

          def redo!
            prototype.redo_apply!
          end

          def cancel!
            prototype.cancel!
          end

          def close!
            prototype.close!
          end

          private

          def prototype
            CellSpaceConversionPreflightPrototype
          end

          def schedule_terminal_report
            UI.start_timer(0.1, false) { poll_terminal }
          end

          def poll_terminal
            phase = prototype.progress_apply_phase!
            unless TERMINAL_PHASES.include?(phase)
              schedule_terminal_report
              return false
            end

            puts "[CELLSPACE PROGRESS APPLY RUNNER] terminal phase=#{phase}"
            snapshot = prototype.status!
            expected = if phase == :completed
                         :converted
                       elsif snapshot[:apply_history_available]
                         :applied
                       else
                         :not_applied
                       end
            prototype.verify_apply!(expected)

            if snapshot[:apply_history_available]
              puts '[CELLSPACE PROGRESS APPLY RUNNER] Undo: ...::CellSpaceConversionProgressApplyRunner.undo!'
              puts '[CELLSPACE PROGRESS APPLY RUNNER] Verify Undo: ...::CellSpaceConversionProgressApplyRunner.verify!(:undone)'
              puts '[CELLSPACE PROGRESS APPLY RUNNER] Redo: ...::CellSpaceConversionProgressApplyRunner.redo!'
              puts '[CELLSPACE PROGRESS APPLY RUNNER] Verify Redo: ...::CellSpaceConversionProgressApplyRunner.verify!(:redone)'
            else
              puts '[CELLSPACE PROGRESS APPLY RUNNER] 실제 적용 이력이 없으므로 Undo/Redo는 차단됩니다.'
            end
            false
          rescue StandardError => e
            puts "[CELLSPACE PROGRESS APPLY RUNNER] terminal report failed: #{e.class}: #{e.message}"
            false
          end
        end
      end
    end
  end
end

runner =
  ULOL::Indoor3DGmlModeler::IndoorCore::
    CellSpaceConversionProgressApplyRunner

runner.run!
