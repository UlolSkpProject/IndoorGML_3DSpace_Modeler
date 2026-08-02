# frozen_string_literal: true

require_relative 'cell_space_conversion_progress_apply_patch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceConversionPreflightPrototype
        class Controller
          EmptyApplyResult = Struct.new(:converted_count, :errors, keyword_init: true)
          EMPTY_APPLY_RESULT = EmptyApplyResult.new(converted_count: 0, errors: [].freeze).freeze

          unless method_defined?(:start_apply_job_without_context_guard)
            alias_method :start_apply_job_without_context_guard, :start_apply_job
          end

          def start_apply_job(**options)
            @apply_result = EMPTY_APPLY_RESULT
            indoor_model = IndoorModel.current
            if indoor_model.editing? || indoor_model.validation_focus_active?
              @apply_mode = true
              @apply_phase = :blocked
              @apply_error_class = nil
              @apply_error_message = 'Edit Mode/validation-focus requires a separate source-preservation contract'
              @before_feature_counts = feature_counts(indoor_model)
              @after_feature_counts = nil
              @state.apply(
                type: :cancelled,
                total: 0,
                completed: 0,
                percent: 0.0,
                message: '실제 적용 차단: Edit Mode/validation-focus 컨텍스트'
              )
              puts '[CELLSPACE PROGRESS APPLY] blocked: Edit Mode/validation-focus requires a separate source-preservation contract'
              return false
            end

            started = start_apply_job_without_context_guard(**options)
            @apply_result ||= EMPTY_APPLY_RESULT
            started
          rescue StandardError
            @apply_result ||= EMPTY_APPLY_RESULT
            raise
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
