# frozen_string_literal: true

require_relative 'cell_space_conversion_progress_apply_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        class Controller
          unless method_defined?(:start_apply_job_without_context_guard)
            alias_method :start_apply_job_without_context_guard, :start_apply_job
          end

          def start_apply_job(**options)
            indoor_model = IndoorModel.current
            if indoor_model.editing? || indoor_model.validation_focus_active?
              puts '[CELLSPACE PROGRESS APPLY] blocked: Edit Mode/validation-focus requires a separate source-preservation contract'
              return false
            end

            start_apply_job_without_context_guard(**options)
          end

          def progress_apply_phase
            @apply_phase
          end
        end

        class << self
          def progress_apply_phase!
            controller.progress_apply_phase
          end
        end
      end
    end
  end
end

puts '[CELLSPACE CONVERSION PROGRESS APPLY SAFETY PATCH] installed'
