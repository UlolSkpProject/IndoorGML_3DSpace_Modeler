# frozen_string_literal: true

require_relative '../../ui/ui_feedback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        # IndoorModel-facing UI policy. Model mutations complete first and their
        # result is reported non-modally. This avoids registering a new timer from
        # the fragile post-bulk callback context.
        module UiFeedbackIntegration
          def convert_selected_solid_groups_to_cell_spaces(selection_value, storey = nil)
            return false if validation_focus_recheck_running?

            cell_type, category_code = CellSpaceCategory.parse_selection_value(selection_value)
            model = Sketchup.active_model
            unless prepare_cell_space_creation_active_context(model)
              raise 'Failed to prepare active context for CellSpace conversion'
            end

            jobs = selected_cell_space_conversion_jobs
            return false if jobs.empty?

            requested_storey = storey.to_s.strip
            jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(jobs, requested_storey)
            original_active_path = ActivePathController.new(model, logger: IndoorCore::Logger).snapshot
            result = convert_cell_space_jobs_bulk(
              jobs,
              fallback_target: [cell_type, category_code],
              original_active_path: original_active_path,
              preserve_source: method(:inside_primal_group?),
              operation_name: 'Convert Selected Solid Groups to CellSpaces',
              activate_root_context: true
            )

            @editor_session.selection_changed
            model.active_view.invalidate if model&.active_view
            publish_cell_space_conversion_result(result)
            true
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Selected solid group conversion failed: #{e.class}: #{e.message}"
            )
            UiFeedback.notify("CellSpace conversion failed:\n#{e.message}")
            false
          end

          private

          def publish_cell_space_conversion_result(result)
            message = ConversionMessageFormatter.result_message(
              result.converted_count,
              result.errors
            )
            UiFeedback.publish_result(message, errors: result.errors)
          end

          def defer_ui_message(message)
            UiFeedback.notify(message)
          end
        end
      end
    end
  end
end
