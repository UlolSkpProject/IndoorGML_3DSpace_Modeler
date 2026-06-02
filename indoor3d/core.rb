require 'sketchup.rb'
require 'fileutils'

module ULOL
  include Sketchup
  include Geom
  module Indoor3DGmlModeler

    load File.join(__dir__, 'classes', 'Gml', 'gml.rb')
    load File.join(__dir__, 'classes', 'IndoorCore', 'IndoorCore.rb')

    def self.attach_model_observer
      begin
        @app_observer ||= IndoorCore::Indoor3DGmlAppObserver.new
        Sketchup.add_observer(@app_observer)
        @app_observer.register_model(Sketchup.active_model())
        IndoorCore::IndoorModel.current.refresh_runtime_data()
      rescue StandardError => e
        puts "[IndoorGML] Model observer setup failed: #{e.class}: #{e.message}"
      end
    end

    def self.convert_selected_solid_groups_to_cell_spaces
      begin
        model = Sketchup.active_model()
        original_active_path = active_path_snapshot(model)
        groups = model.selection().grep(Sketchup::Group)
        solid_groups = groups.select { |group| group.valid?() && group.manifold?() }

        if solid_groups.empty?
          UI.messagebox('Select one or more solid groups to convert to CellSpace.')
          return
        end

        cell_type, category_code = prompt_cell_space_type_and_category('Convert Solid Groups to CellSpace')
        return if cell_type.nil?

        indoor_model = IndoorCore::IndoorModel.current
        converted_count = 0
        errors = []

        model.start_operation('Convert Solid Groups to CellSpace', true)
        indoor_model.with_active_path_enforcement_suspended do
          root_solid_groups = move_groups_to_root_context(model, solid_groups)
          activate_root_context(model)
          root_solid_groups.each do |group|
            begin
              indoor_model.convert_group_to_cell_space(group, cell_type, category_code)
              converted_count += 1
            rescue StandardError => e
              puts "[IndoorGML] CellSpace conversion failed: #{e.class}: #{e.message}"
              errors << "#{e.class}: #{e.message}"
            end
          end
          restore_active_path(model, original_active_path)
        end
        model.commit_operation()

        message = "Converted #{converted_count} CellSpace(s)."
        message += "\nFailed #{errors.length} group(s):\n#{errors.join("\n")}" if errors.any?()
        UI.messagebox(message)
      rescue StandardError => e
        if model && original_active_path
          IndoorCore::IndoorModel.current.with_active_path_enforcement_suspended do
            restore_active_path(model, original_active_path)
          end
        end
        model.abort_operation() if model
        UI.messagebox("CellSpace conversion failed:\n#{e.message}")
      end
    end

    def self.change_selected_cell_space_type
      model = Sketchup.active_model
      groups = model.selection.grep(Sketchup::Group)

      if groups.empty?
        UI.messagebox('Select one or more CellSpace groups to change type.')
        return
      end

      cell_type, category_code = prompt_cell_space_type_and_category('Change CellSpace Type')
      return if cell_type.nil?

      indoor_model = IndoorCore::IndoorModel.current
      changed_count = 0
      errors = []

      model.start_operation('Change CellSpace Type', true)
      groups.each do |group|
        begin
          indoor_model.change_cell_space_type(group, cell_type, category_code)
          changed_count += 1
        rescue StandardError => e
          puts "[IndoorGML] CellSpace type change failed: #{e.class}: #{e.message}"
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

    def self.refresh_runtime_data
      IndoorCore::IndoorModel.current.refresh_runtime_data
      UI.messagebox('IndoorGML runtime data refreshed.')
    rescue StandardError => e
      UI.messagebox("Runtime refresh failed:\n#{e.message}")
    end

    def self.create_temp_indoorgml
      begin
        coordinate_system = prompt_export_coordinate_system
        return if coordinate_system.nil?

        output_path = IndoorCore::IndoorGmlConverter::TempExporter.new(
          IndoorCore::IndoorModel.current,
          coordinate_system: coordinate_system
        ).export
        UI.messagebox("IndoorGML temp.gml created:\n#{output_path}")
      rescue StandardError => e
        UI.messagebox("IndoorGML temp.gml creation failed:\n#{e.message}")
      end
    end

    def self.export_indoorgml
      coordinate_system = prompt_export_coordinate_system
      return if coordinate_system.nil?

      progress = IndoorCore::IndoorGmlConverter::ExportProgressDialog.new
      progress.show
      UI.start_timer(0.1, false) do
        perform_export_indoorgml(progress, coordinate_system)
      end
    rescue StandardError => e
      progress&.close
      UI.messagebox("IndoorGML export failed:\n#{e.message}")
    end

    def self.perform_export_indoorgml(progress, coordinate_system)
      current_step = :runtime
      begin
        indoor_model = IndoorCore::IndoorModel.current
        current_step = :runtime
        progress.running(:runtime)
        indoor_model.refresh_runtime_data
        progress.complete(:runtime)

        current_step = :temp_file
        progress.running(:temp_file)
        temp_path = IndoorCore::IndoorGmlConverter::TempExporter.new(
          indoor_model,
          refresh_runtime_data: false,
          coordinate_system: coordinate_system
        ).export
        progress.complete(:temp_file)
        validator = IndoorCore::IndoorGmlConverter::Val3dityRunner.new(temp_path)

        current_step = :val3dity
        if validator.validate(progress: progress)
          progress&.close
          path = UI.savepanel('Export IndoorGML', '~', 'IndoorGML Files|*.gml;||')
          return if path.to_s.empty?

          path = "#{path}.gml" unless File.extname(path).downcase == '.gml'
          FileUtils.mkdir_p(File.dirname(path))
          FileUtils.cp(temp_path, path)
          UI.messagebox("IndoorGML exported:\n#{path}")
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
        UI.messagebox("IndoorGML export failed:\n#{e.message}")
      ensure
        progress&.close
      end
    end

    def self.open_local_file(path)
      UI.openURL("file:///#{File.expand_path(path).tr('\\', '/')}")
    end

    def self.begin_indoor_gml_editing
      begin
        indoor_model = IndoorCore::IndoorModel.current
        if indoor_model.editing?()
          UI.messagebox('IndoorGML editing is already active.')
        elsif !indoor_model.begin_editing()
          UI.messagebox('IndoorGML PrimalSpaceFeatures group was not found.')
        end
      rescue StandardError => e
        UI.messagebox("IndoorGML editing failed:\n#{e.message}")
      end
    end

    def self.finish_indoor_gml_editing
      begin
        if IndoorCore::IndoorModel.current.finish_editing()
          UI.messagebox('IndoorGML editing finished.')
        else
          UI.messagebox('IndoorGML editing is not active.')
        end
      rescue StandardError => e
        UI.messagebox("IndoorGML editing finish failed:\n#{e.message}")
      end
    end

    def self.toggle_indoor_gml_editing
      begin
        indoor_model = IndoorCore::IndoorModel.current
        if indoor_model.editing?()
          finish_indoor_gml_editing()
        else
          begin_indoor_gml_editing()
        end
      rescue StandardError => e
        UI.messagebox("IndoorGML editing toggle failed:\n#{e.message}")
      end
    end

    def self.create_command(label, tooltip, &block)
      command = UI::Command.new(label) { block.call() }
      command.tooltip = tooltip
      command.status_bar_text = tooltip
      command
    end

    def self.prompt_cell_space_type_and_category(title)
      options = IndoorCore::CellSpaceCategory.selection_options
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

    def self.prompt_export_coordinate_system
      labels = [
        'Z-up RH (IndoorGML Standard)',
        'Y-up LH (Unity / InViewerDesktop)'
      ]
      result = UI.inputbox(
        ['Coordinate System'],
        [labels.first],
        [labels.join('|')],
        'Export IndoorGML'
      )
      return nil unless result

      result.first == labels.last ? :y_up_lh : :z_up_rh
    end

    def self.add_context_menu_items(menu)
      indoor_model = IndoorCore::IndoorModel.current
      selected_indoor_entities = selected_indoor_gml_entities()
      selected_cell_spaces = selected_indoor_entities.select { |entity| indoor_feature(entity) == 'CellSpace' }

      if !indoor_model.editing?() && selected_indoor_entities.any?()
        menu.add_item('Edit IndoorGML') { begin_indoor_gml_editing() }
      end

      if indoor_model.editing?() && selected_cell_spaces.any?()
        menu.add_item('Change CellSpace Type') { change_selected_cell_space_type() }
      end
    rescue StandardError => e
      puts "[IndoorGML] Context menu failed: #{e.class}: #{e.message}"
    end

    def self.selected_indoor_gml_entities
      Sketchup.active_model.selection.to_a.select do |entity|
        entity&.valid? && indoor_feature(entity).to_s.length.positive?
      end
    end

    def self.indoor_feature(entity)
      entity.get_attribute(IndoorCore::IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
    rescue StandardError
      nil
    end

    def self.active_path_snapshot(model)
      path = model.active_path()
      path ? path.dup : nil
    end

    def self.activate_root_context(model)
      model.close_active() while model.active_path()
    end

    def self.restore_active_path(model, active_path)
      begin
        return unless active_path

        valid_path = active_path.select { |entity| entity&.valid?() }
        return if valid_path.empty?()

        if model.respond_to?(:active_path=)
          model.active_path = valid_path
        end
      rescue StandardError => e
        puts "[IndoorGML] Edit context restore failed: #{e.class}: #{e.message}"
      end
    end

    def self.move_groups_to_root_context(model, groups)
      return groups if model.active_path().nil?

      groups.map { |group| move_group_to_root_context(model, group) }.compact
    end

    def self.move_group_to_root_context(model, group)
      return group unless group&.valid?()

      transformation = Utils::Transformation.entity_world_transformation(group)
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

    unless file_loaded?(__FILE__)
      attach_model_observer()
      menu = UI.menu('Extensions').add_submenu('Indoor3DGML Modeler')
      menu.add_item('Convert Solid Groups to CellSpace') do
        convert_selected_solid_groups_to_cell_spaces()
      end
      menu.add_item('Refresh Runtime Data') do
        refresh_runtime_data()
      end
      menu.add_item('Create temp.gml') do
        create_temp_indoorgml()
      end
      menu.add_item('Export IndoorGML') do
        export_indoorgml()
      end
      edit_command = create_command('Edit IndoorGML', 'Toggle IndoorGML editing mode') do
        toggle_indoor_gml_editing()
      end
      export_command = create_command('Export IndoorGML', 'Export the current model to IndoorGML') do
        export_indoorgml()
      end

      UI.add_context_menu_handler do |context_menu|
        add_context_menu_items(context_menu)
      end

      toolbar = UI::Toolbar.new('Indoor3DGML Modeler')
      toolbar.add_item(edit_command)
      toolbar.add_item(export_command)
      toolbar.show()
      file_loaded(__FILE__)
    end

  end
end
