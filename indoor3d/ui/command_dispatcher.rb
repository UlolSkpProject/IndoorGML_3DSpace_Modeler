# frozen_string_literal: true

require 'fileutils'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CommandDispatcher
        attr_accessor :dual_overlay_command
        attr_accessor :geometry_command

        def convert_selected_solid_groups_to_cell_spaces
          begin
            model = Sketchup.active_model()
            original_active_path = active_path_snapshot(model)
            groups = model.selection().grep(Sketchup::Group)
            solid_groups = groups.select { |group| group.valid?() && group.manifold?() }

            if solid_groups.empty?
              UI.messagebox('Select one or more solid groups to convert to CellSpace.')
              return
            end

            rm_groups = solid_groups.select { |group| rm_helper_cell_space_type_and_category(group) }
            non_rm_groups = solid_groups - rm_groups

            if non_rm_groups.any?
              cell_type, category_code = prompt_cell_space_type_and_category('Convert Solid Groups to CellSpace')
              return if cell_type.nil?
            end

            indoor_model = IndoorModel.current
            converted_count = 0
            errors = []

            model.start_operation('Convert Solid Groups to CellSpace', true)
            indoor_model.with_active_path_enforcement_suspended do
              root_solid_groups = move_groups_to_root_context(model, solid_groups)
              activate_root_context(model)
              if root_solid_groups.empty?
                restore_active_path(model, original_active_path)
                model.abort_operation()
                UI.messagebox('No valid solid groups were available for conversion.')
                return
              end

              scheduled = indoor_model.run_batched(
                root_solid_groups,
                message: 'Converting CellSpaces...',
                batch_size: 20,
                complete: proc do
                  indoor_model.with_active_path_enforcement_suspended do
                    restore_active_path(model, original_active_path)
                  end
                  model.commit_operation()

                  UI.messagebox(cell_space_conversion_result_message(converted_count, errors))
                end,
                failure: proc do |error|
                  indoor_model.with_active_path_enforcement_suspended do
                    restore_active_path(model, original_active_path)
                  end
                  model.abort_operation()
                  UI.messagebox("CellSpace conversion failed:\n#{error.message}")
                end
              ) do |group, _index|
                begin
                  target_cell_type, target_category_code = RmHelperAdapter.resolve_cell_space_type_and_category(
                    group,
                    cell_type,
                    category_code
                  )
                  indoor_model.convert_single_group_to_cell_space(group, target_cell_type, target_category_code)
                  converted_count += 1
                rescue StandardError => e
                  Logger.puts "[IndoorGML] CellSpace conversion failed: #{e.class}: #{e.message}"
                  errors << { group: cell_space_conversion_group_label(group), reason: e.message }
                end
              end
              unless scheduled
                restore_active_path(model, original_active_path)
                model.abort_operation()
                UI.messagebox('CellSpace conversion could not be scheduled.')
              end
            end
          rescue StandardError => e
            if model && original_active_path
              IndoorModel.current.with_active_path_enforcement_suspended do
                restore_active_path(model, original_active_path)
              end
            end
            model.abort_operation() if model
            UI.messagebox("CellSpace conversion failed:\n#{e.message}")
          end
        end

        def change_selected_cell_space_type
          model = Sketchup.active_model
          groups = model.selection.grep(Sketchup::Group)

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
            UI.messagebox('Selected CellSpace type is locked by RM_helper and already matches the mapped type.')
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

        def refresh_runtime_data
          IndoorModel.current.refresh_runtime_data
          UI.messagebox('IndoorGML runtime data refreshed.')
        rescue StandardError => e
          UI.messagebox("Runtime refresh failed:\n#{e.message}")
        end

        def create_temp_indoorgml
          begin
            output_path = IndoorGmlConverter::GmlExporter.new(IndoorModel.current).export
            UI.messagebox("IndoorGML temp.gml created:\n#{output_path}")
          rescue StandardError => e
            UI.messagebox("IndoorGML temp.gml creation failed:\n#{e.message}")
          end
        end

        def export_gml
          path = UI.savepanel('Export GML', '~', 'IndoorGML Files|*.gml;||')
          return if path.to_s.empty?

          path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
          FileUtils.mkdir_p(File.dirname(path))
          IndoorGmlConverter::GmlExporter.new(IndoorModel.current).export(output_path: path)
          UI.messagebox("GML exported:\n#{path}")
        rescue StandardError => e
          UI.messagebox("GML export failed:\n#{e.message}")
        end

        def check_validity
          progress = IndoorGmlConverter::ExportProgressDialog.new
          progress.show
          UI.start_timer(0.1, false) do
            perform_check_validity(progress)
          end
        rescue StandardError => e
          progress&.close
          UI.messagebox("IndoorGML validity check failed:\n#{e.message}")
        end

        def perform_check_validity(progress)
          current_step = :runtime
          begin
            indoor_model = IndoorModel.current
            current_step = :runtime
            progress.running(:runtime)
            indoor_model.refresh_runtime_data
            progress.complete(:runtime)

            current_step = :temp_file
            progress.running(:temp_file)
            temp_path = IndoorGmlConverter::GmlExporter.new(
              indoor_model,
              refresh_runtime_data: false
            ).export
            progress.complete(:temp_file)
            validator = IndoorGmlConverter::Val3dityRunner.new(temp_path)

            current_step = :val3dity
            if validator.validate(progress: progress)
              progress&.close
              unless UI.messagebox("IndoorGML validation succeeded.\nExport GML now?", MB_YESNO) == IDYES
                return
              end

              path = UI.savepanel('Export GML', '~', 'IndoorGML Files|*.gml;||')
              return if path.to_s.empty?

              path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
              FileUtils.mkdir_p(File.dirname(path))
              FileUtils.cp(temp_path, path)
              UI.messagebox("GML exported:\n#{path}")
            else
              progress&.close
              if UI.messagebox("IndoorGML validation failed.\nOpen validation report?", MB_YESNO) == IDYES
                open_local_file(validator.report_html_path)
              end
              if UI.messagebox('Open temporary GML file?', MB_YESNO) == IDYES
                open_local_file(temp_path)
              end
            end
          rescue StandardError => e
            progress&.fail(current_step)
            UI.messagebox("IndoorGML validity check failed:\n#{e.message}")
          ensure
            progress&.close
          end
        end

        def open_local_file(path)
          UI.openURL("file:///#{File.expand_path(path).tr('\\', '/')}")
        end

        def begin_indoor_gml_editing
          begin
            indoor_model = IndoorModel.current
            if indoor_model.editing?()
              UI.messagebox('IndoorGML editing is already active.')
            elsif !indoor_model.begin_editing()
              UI.messagebox('IndoorGML PrimalSpaceFeatures group was not found.')
            end
          rescue StandardError => e
            UI.messagebox("IndoorGML editing failed:\n#{e.message}")
          end
        end

        def finish_indoor_gml_editing
          begin
            unless IndoorModel.current.finish_editing()
              UI.messagebox('IndoorGML editing is not active.')
            end
          rescue StandardError => e
            UI.messagebox("IndoorGML editing finish failed:\n#{e.message}")
          end
        end

        def toggle_indoor_gml_editing
          begin
            indoor_model = IndoorModel.current
            if indoor_model.editing?()
              finish_indoor_gml_editing()
            else
              begin_indoor_gml_editing()
            end
          rescue StandardError => e
            UI.messagebox("IndoorGML editing toggle failed:\n#{e.message}")
          end
        end

        def update_dual_overlay_command
          return unless @dual_overlay_command

          if IndoorModel.current.dual_overlay_visible?
            @dual_overlay_command.menu_text = 'Hide State/Link Overlay'
            @dual_overlay_command.tooltip = 'Hide State and Transition overlay'
            @dual_overlay_command.status_bar_text = 'Hide State and Transition overlay'
          else
            @dual_overlay_command.menu_text = 'Show State/Link Overlay'
            @dual_overlay_command.tooltip = 'Show State and Transition overlay'
            @dual_overlay_command.status_bar_text = 'Show State and Transition overlay'
          end
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay command update failed: #{e.class}: #{e.message}"
        end

        def update_geometry_command
          return unless @geometry_command

          if IndoorModel.current.geometry_visible?
            @geometry_command.menu_text = 'Hide Geometry'
            @geometry_command.tooltip = 'Hide CellSpace geometry'
            @geometry_command.status_bar_text = 'Hide CellSpace geometry'
          else
            @geometry_command.menu_text = 'Show Geometry'
            @geometry_command.tooltip = 'Show CellSpace geometry'
            @geometry_command.status_bar_text = 'Show CellSpace geometry'
          end
        rescue StandardError => e
          Logger.puts "[IndoorGML] Geometry command update failed: #{e.class}: #{e.message}"
        end

        def toggle_dual_overlay
          IndoorModel.current.toggle_dual_overlay_visible()
          update_dual_overlay_command()
        rescue StandardError => e
          UI.messagebox("State/Link overlay toggle failed:\n#{e.message}")
        end

        def toggle_geometry
          IndoorModel.current.toggle_geometry_visible()
          update_geometry_command()
        rescue StandardError => e
          UI.messagebox("Geometry toggle failed:\n#{e.message}")
        end

        def add_context_menu_items(menu)
          indoor_model = IndoorModel.current
          selected_indoor_entities = selected_indoor_gml_entities()
          selected_cell_spaces = selected_indoor_entities.select { |entity| indoor_feature(entity) == 'CellSpace' }

          if !indoor_model.editing?() && selected_indoor_entities.any?()
            menu.add_item('Edit IndoorGML') { begin_indoor_gml_editing() }
          end

          if indoor_model.editing?() && cell_space_type_change_available?(selected_cell_spaces)
            menu.add_item('Change CellSpace Type') { change_selected_cell_space_type() }
          end
        rescue StandardError => e
          Logger.puts "[IndoorGML] Context menu failed: #{e.class}: #{e.message}"
        end

        def selected_indoor_gml_entities
          Sketchup.active_model.selection.to_a.select do |entity|
            entity&.valid? && indoor_feature(entity).to_s.length.positive?
          end
        end

        def indoor_feature(entity)
          entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
        rescue StandardError
          nil
        end

        def cell_space_type_change_available?(groups)
          cell_space_groups = Array(groups).select { |group| indoor_feature(group) == 'CellSpace' }
          return false if cell_space_groups.empty?

          !cell_space_groups.all? { |group| rm_helper_cell_space_type_matches_indoor_attributes?(group) }
        end

        private

        def rm_helper_cell_space_type_and_category(group)
          RmHelperAdapter.cell_space_type_and_category(group)
        end

        def prompt_cell_space_type_and_category(title)
          options = CellSpaceCategory.selection_options
          labels = options.map { |option| option[:label] }
          result = UI.inputbox(
            ['CellSpace'],
            [labels.first],
            [labels.join('|')],
            title
          )
          return nil unless result

          option = options.find { |candidate| candidate[:label] == result.first } || options.first
          [option[:cell_type], option[:category_code]]
        end

        def rm_helper_cell_space_type_matches_indoor_attributes?(group)
          target = rm_helper_cell_space_type_and_category(group)
          return false if target.nil?

          current_type = CellSpaceType.from_label(
            group.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'cell_type')
          )
          current_category_code = group.get_attribute(
            IndoorModel::ATTRIBUTE_DICTIONARY_NAME,
            'category_code'
          ).to_s
          current_type == target[0] && current_category_code == target[1]
        rescue StandardError
          false
        end

        def active_path_snapshot(model)
          path = model.active_path()
          path ? path.dup : nil
        end

        def activate_root_context(model)
          model.close_active() while model.active_path()
        end

        def restore_active_path(model, active_path)
          begin
            return unless active_path

            valid_path = active_path.select { |entity| entity&.valid?() }
            return if valid_path.empty?()

            if model.respond_to?(:active_path=)
              model.active_path = valid_path
            end
          rescue StandardError => e
            Logger.puts "[IndoorGML] Edit context restore failed: #{e.class}: #{e.message}"
          end
        end

        def move_groups_to_root_context(model, groups)
          return groups if model.active_path().nil?

          groups.map { |group| move_group_to_root_context(model, group) }.compact
        end

        def move_group_to_root_context(model, group)
          return group unless group&.valid?()

          transformation = Utils::Transformation.entity_transformation_in_active_context(group)
          copy = model.entities().add_instance(group.definition, transformation)
          copy = copy.to_group() if copy.respond_to?(:to_group)
          copy.make_unique() if copy.respond_to?(:make_unique)
          copy.name = group.name if copy.respond_to?(:name=)
          copy.material = group.material if copy.respond_to?(:material=)
          copy.layer = group.layer if copy.respond_to?(:layer=)
          copy.visible = group.visible?() if copy.respond_to?(:visible=)
          group.erase!() if group.valid?()
          copy
        end

        def cell_space_conversion_group_label(group)
          name = group.respond_to?(:name) ? group.name.to_s.strip : ''
          id = group.respond_to?(:entityID) ? group.entityID : nil
          return "#{name} (entity #{id})" unless name.empty? || id.nil?
          return name unless name.empty?
          return "entity #{id}" unless id.nil?

          'unknown group'
        end

        def cell_space_conversion_result_message(converted_count, errors)
          message = +"Succeed : #{converted_count}\nFailed : #{errors.length}"
          return message if errors.empty?

          grouped_errors = errors.group_by { |error| cell_space_conversion_reason_label(error[:reason]) }
          grouped_errors.each do |reason, entries|
            message << "\n- #{reason}"
            entries.each do |entry|
              message << "\n  #{entry[:group]}"
            end
          end
          message
        end

        def cell_space_conversion_reason_label(reason)
          return 'SolidGroup내 분리된 형상' if reason.to_s.include?('Disconnected solid shells detected')

          reason.to_s.empty? ? '알 수 없는 실패 원인' : reason.to_s
        end
      end
    end
  end
end
