# frozen_string_literal: true

require_relative '../ui_feedback'
require_relative '../cell_space_create_dialog'
require_relative '../../application/progress/production_progress_session'
require_relative '../overlays/production_progress_overlay'
require_relative '../../application/progress/cell_space_create_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceCommands
        def convert_selected_solid_groups_to_cell_spaces
          open_cell_space_create_dialog(local_grid: false)
        end

        # Optional command. It intentionally is not connected to the
        # existing menu command so the current CellSpace creation path stays intact.
        def convert_selected_solid_groups_to_cell_spaces_local_grid
          open_cell_space_create_dialog(local_grid: true)
        end

        def change_selected_cell_space_type
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          model = Sketchup.active_model
          groups = model.selection.to_a.select { |entity| convertible_container?(entity) }

          if groups.empty?
            UiFeedback.notify('Select one or more CellSpace groups to change type.')
            return
          end

          cell_space_groups = groups.select { |group| indoor_feature(group) == 'CellSpace' }
          if cell_space_groups.empty?
            UiFeedback.notify('Select one or more CellSpace groups to change type.')
            return
          end

          unless cell_space_type_change_available?(cell_space_groups)
            UiFeedback.notify('Selected CellSpace type is locked by Tag and already matches the mapped type.')
            return
          end

          cell_type, category_code = prompt_cell_space_type_and_category('Change CellSpace Type')
          return if cell_type.nil?

          indoor_model = IndoorModel.current
          changed = indoor_model.change_cell_space_types(
            cell_space_groups,
            cell_type,
            category_code,
            operation_name: 'Change CellSpace Type'
          )
          UiFeedback.notify("Changed #{changed.length} CellSpace type(s).")
        rescue StandardError => e
          UiFeedback.notify("CellSpace type change failed:\n#{e.message}")
        end

        private

        def open_cell_space_create_dialog(local_grid:)
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          model = Sketchup.active_model
          indoor_model = IndoorModel.current
          unless indoor_model.prepare_cell_space_creation_active_context(model)
            raise 'Failed to prepare active context for CellSpace conversion'
          end

          original_active_path = active_path_snapshot(model)
          groups = model.selection.to_a.select { |entity| convertible_container?(entity) }
          conversion_jobs = CellSpaceConversionJobBuilder.new(entities: groups).build
          if conversion_jobs.empty?
            UiFeedback.notify('Select one or more solid groups to convert to CellSpace.')
            return
          end

          targets = conversion_jobs.map { |job| job[:target] }.compact.uniq
          storeys = conversion_jobs.map { |job| job[:storey].to_s }.reject(&:empty?).uniq
          default_target = targets.length == 1 ? targets.first : nil
          default_storey = storeys.length == 1 ? storeys.first : CellSpace::DEFAULT_STOREY
          title = local_grid ? 'Create CellSpace · Local Grid' : 'Create CellSpace'
          payload = cell_space_creation_dialog_payload(
            title,
            default_target: default_target,
            default_storey: default_storey
          )
          return unless payload

          @cell_space_create_dialog&.close
          dialog = CellSpaceCreateDialog.new
          @cell_space_create_dialog = dialog
          dialog.show(payload) do |selection|
            execute_cell_space_create_dialog(
              dialog: dialog,
              model: model,
              indoor_model: indoor_model,
              original_active_path: original_active_path,
              groups: groups,
              default_target: default_target,
              selection: selection,
              local_grid: local_grid
            )
          end
          dialog
        rescue StandardError => error
          IndoorCore::Logger.puts(
            "[IndoorGML] Create CellSpace dialog failed: #{error.class}: #{error.message}"
          )
          UiFeedback.notify("CellSpace creation failed: #{error.message}")
          nil
        end

        def execute_cell_space_create_dialog(dialog:, model:, indoor_model:, original_active_path:, groups:, default_target:, selection:, local_grid:)
          progress_session = nil
          raise 'The active model changed while Create CellSpace was open.' unless Sketchup.active_model.equal?(model)

          cell_type, category_code, storey = resolve_cell_space_creation_dialog_selection(
            selection,
            default_target: default_target
          )

          valid_groups = groups.select do |group|
            group.respond_to?(:valid?) ? group.valid? : true
          rescue StandardError
            false
          end
          conversion_jobs = CellSpaceConversionJobBuilder.new(entities: valid_groups).build
          conversion_jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(conversion_jobs, storey)
          raise 'No valid Solid Groups remain for CellSpace creation.' if conversion_jobs.empty?

          result =
            if local_grid
              indoor_model.convert_cell_space_jobs_bulk_local_grid(
                conversion_jobs,
                fallback_target: [cell_type, category_code],
                original_active_path: original_active_path,
                operation_name: 'Convert Solid Groups to CellSpace Local Grid',
                activate_root_context: true
              )
            else
              progress_session = start_cell_space_create_progress(model, conversion_jobs.length)
              ProductionProgress::CellSpaceProgressContext.with(progress_session) do
                indoor_model.convert_cell_space_jobs_bulk(
                  conversion_jobs,
                  fallback_target: [cell_type, category_code],
                  original_active_path: original_active_path,
                  operation_name: 'Convert Solid Groups to CellSpace',
                  activate_root_context: true
                )
              end
            end

          finish_cell_space_create_progress(progress_session, result) unless local_grid
          close_cell_space_create_progress(progress_session)
          progress_session = nil
          dialog.show_result(result, title: 'CellSpace 생성 완료')
          result
        rescue StandardError => error
          fail_cell_space_create_progress(progress_session, error)
          close_cell_space_create_progress(progress_session)
          progress_session = nil

          if model && original_active_path
            IndoorModel.current.with_active_path_enforcement_suspended do
              restore_active_path(model, original_active_path)
            end
          end

          IndoorCore::Logger.puts(
            "[IndoorGML] CellSpace creation failed: #{error.class}: #{error.message}"
          )
          dialog.show_error(error.message, title: 'CellSpace 생성 실패')
          nil
        ensure
          close_cell_space_create_progress(progress_session)
        end

        def start_cell_space_create_progress(model, job_count)
          session = ProductionProgress::ProductionProgressSession.new(
            title: 'CellSpace 생성',
            total: job_count,
            renderer: ProductionProgress::SketchupOverlayProgressRenderer.new(model: model),
            cancellable: false,
            metadata: {
              operation: :cell_space_create,
              job_count: job_count
            }
          )
          session.start(message: "CellSpace 생성 준비: #{job_count}개")
          session
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace progress start failed: #{e.class}: #{e.message}"
          nil
        end

        def finish_cell_space_create_progress(session, result)
          return unless session&.active?

          converted_count = result.converted_count.to_i
          error_count = Array(result.errors).length
          session.complete(
            message: "CellSpace 생성 완료: #{converted_count}개",
            telemetry: {
              converted_count: converted_count,
              error_count: error_count,
              metrics: result.metrics || {}
            }
          )
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace progress completion failed: #{e.class}: #{e.message}"
          nil
        end

        def fail_cell_space_create_progress(session, error)
          return unless session&.active?

          session.fail(error, message: "CellSpace 생성 실패: #{error.message}")
        rescue StandardError => progress_error
          IndoorCore::Logger.puts(
            "[IndoorGML] CellSpace progress failure reporting failed: " \
            "#{progress_error.class}: #{progress_error.message}"
          )
          nil
        end

        def close_cell_space_create_progress(session)
          session&.close
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] CellSpace progress close failed: #{e.class}: #{e.message}"
          false
        end

        def publish_cell_space_command_result(result, title: 'CellSpace 변환 완료')
          CellSpaceCreateDialog.show_conversion_result(result, title: title)
        end
      end
    end
  end
end
