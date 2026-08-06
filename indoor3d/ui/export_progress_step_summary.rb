# frozen_string_literal: true

require 'json'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module ExportProgressStepSummaryPatch
          def initialize(*arguments, **options)
            super
            @step_summaries = {}
          end

          def set_step_summary(step, message, tone: :neutral)
            payload = {
              step: step.to_s,
              message: message.to_s,
              tone: tone.to_s
            }
            @step_summaries ||= {}
            if payload[:message].empty?
              @step_summaries.delete(payload[:step])
            else
              @step_summaries[payload[:step]] = payload
            end

            execute_or_queue("setStepSummary(#{JSON.generate(payload)});")
            true
          rescue StandardError => error
            IndoorCore::Logger.puts(
              "[IndoorGML] Export progress step summary update failed: " \
              "#{error.class}: #{error.message}"
            )
            false
          end

          private

          def reset_progress_state
            super
            @step_summaries = {}
          end

          def replay_state
            super
            Array(@step_summaries&.values).each do |payload|
              @dialog.execute_script("setStepSummary(#{JSON.generate(payload)});")
            end
          end
        end

        dialog_class = ExportProgressDialog
        unless dialog_class.ancestors.include?(ExportProgressStepSummaryPatch)
          dialog_class.prepend(ExportProgressStepSummaryPatch)
        end
      end
    end
  end
end
