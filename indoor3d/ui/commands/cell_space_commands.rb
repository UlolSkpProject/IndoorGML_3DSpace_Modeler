# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceCommands
        def convert_selected_solid_groups_to_cell_spaces
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          begin
            model = Sketchup.active_model()
            indoor_model = IndoorModel.current
            unless indoor_model.prepare_cell_space_creation_active_context(model)
              raise 'Failed to prepare active context for CellSpace conversion'
            end
            original_active_path = active_path_snapshot(model)
            groups = model.selection().to_a.select { |entity| convertible_container?(entity) }
            conversion_jobs = CellSpaceConversionJobBuilder.new(entities: groups).build

            if conversion_jobs.empty?
              UI.messagebox('Select one or more solid groups to convert to CellSpace.')
              return
            end

            if conversion_jobs.any? { |job| job[:target].nil? }
              cell_type, category_code = prompt_cell_space_type_and_category('Convert Solid Groups to CellSpace')
              return if cell_type.nil?
            end

            result = indoor_model.convert_cell_space_jobs_bulk(
              conversion_jobs,
              fallback_target: [cell_type, category_code],
              original_active_path: original_active_path,
              operation_name: 'Convert Solid Groups to CellSpace',
              activate_root_context: true
            )
            UI.messagebox(ConversionMessageFormatter.result_message(result.converted_count, result.errors))
          rescue StandardError => e
            if model && defined?(original_active_path) && original_active_path
              IndoorModel.current.with_active_path_enforcement_suspended do
                restore_active_path(model, original_active_path)
              end
            end
            UI.messagebox("CellSpace conversion failed:\n#{e.message}")
          end
        end

        def change_selected_cell_space_type
          model = Sketchup.active_model
          groups = model.selection.to_a.select { |entity| convertible_container?(entity) }

          if groups.empty?
            UI.messagebox('Select one or more CellSpace groups to change type.')
            return
          end

          cell_space_groups = groups.select { |group| indoor_feature(group) == 'CellSpace' }
          if cell_space_groups.empty?
            UI.messagebox('Select one or more CellSpace groups to change type.')
            return
          end

          unless cell_space_type_change_available?(cell_space_groups)
            UI.messagebox('Selected CellSpace type is locked by Tag and already matches the mapped type.')
            return
          end

          cell_type, category_code = prompt_cell_space_type_and_category('Change CellSpace Type')
          return if cell_type.nil?

          indoor_model = IndoorModel.current
          changed_count = 0
          errors = []

          model.start_operation('Change CellSpace Type', true)
          cell_space_groups.each do |group|
            begin
              indoor_model.change_cell_space_type(group, cell_type, category_code)
              changed_count += 1
            rescue StandardError => e
              Logger.puts "[IndoorGML] CellSpace type change failed: #{e.class}: #{e.message}"
              errors << "#{group.name}: #{e.message}"
            end
          end
          model.commit_operation

          message = "Changed #{changed_count} CellSpace type(s)."
          message += "\nFailed #{errors.length} group(s):\n#{errors.join("\n")}" if errors.any?
          UI.messagebox(message)
        rescue StandardError => e
          model.abort_operation if model
          UI.messagebox("CellSpace type change failed:\n#{e.message}")
        end

        private

      end
    end
  end
end
