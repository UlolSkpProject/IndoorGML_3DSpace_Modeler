require 'sketchup.rb'

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

        labels = IndoorCore::CellSpaceType::LABELS.values
        result = UI.inputbox(
          ['CellSpace Type'],
          [labels.first],
          [labels.join('|')],
          'Convert Solid Groups to CellSpace'
        )
        return unless result

        cell_type = IndoorCore::CellSpaceType.from_label(result.first)
        indoor_model = IndoorCore::IndoorModel.current
        converted_count = 0
        errors = []

        model.start_operation('Convert Solid Groups to CellSpace', true)
        root_solid_groups = move_groups_to_root_context(model, solid_groups)
        activate_root_context(model)
        root_solid_groups.each do |group|
          begin
            indoor_model.convert_group_to_cell_space(group, cell_type)
            converted_count += 1
          rescue StandardError => e
            puts "[IndoorGML] CellSpace conversion failed: #{e.class}: #{e.message}"
            errors << "#{e.class}: #{e.message}"
          end
        end
        restore_active_path(model, original_active_path)
        model.commit_operation()

        message = "Converted #{converted_count} CellSpace(s)."
        message += "\nFailed #{errors.length} group(s):\n#{errors.join("\n")}" if errors.any?()
        UI.messagebox(message)
      rescue StandardError => e
        restore_active_path(model, original_active_path) if model && original_active_path
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

      labels = IndoorCore::CellSpaceType::LABELS.values
      result = UI.inputbox(
        ['CellSpace Type'],
        [labels.first],
        [labels.join('|')],
        'Change CellSpace Type'
      )
      return unless result

      cell_type = IndoorCore::CellSpaceType.from_label(result.first)
      indoor_model = IndoorCore::IndoorModel.current
      changed_count = 0
      errors = []

      model.start_operation('Change CellSpace Type', true)
      groups.each do |group|
        begin
          indoor_model.change_cell_space_type(group, cell_type)
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

    def self.begin_indoor_gml_editing
      if IndoorCore::IndoorModel.current.begin_editing
        UI.messagebox('IndoorGML editing started.')
      else
        UI.messagebox('IndoorGML editing is already active.')
      end
    rescue StandardError => e
      UI.messagebox("IndoorGML editing failed:\n#{e.message}")
    end

    def self.finish_indoor_gml_editing
      if IndoorCore::IndoorModel.current.finish_editing
        UI.messagebox('IndoorGML editing finished.')
      else
        UI.messagebox('IndoorGML editing is not active.')
      end
    rescue StandardError => e
      UI.messagebox("IndoorGML editing finish failed:\n#{e.message}")
    end

    def self.create_command(label, tooltip, &block)
      command = UI::Command.new(label) { block.call() }
      command.tooltip = tooltip
      command.status_bar_text = tooltip
      command
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
      menu.add_item('Change CellSpace Type') do
        change_selected_cell_space_type()
      end
      menu.add_item('Refresh Runtime Data') do
        refresh_runtime_data()
      end
      edit_command = create_command('Edit IndoorGML', 'Enter IndoorGML editing mode') do
        begin_indoor_gml_editing()
      end
      finish_command = create_command('Finish IndoorGML Editing', 'Finish IndoorGML editing mode') do
        finish_indoor_gml_editing()
      end
      menu.add_item(edit_command)
      menu.add_item(finish_command)

      toolbar = UI::Toolbar.new('Indoor3DGML Modeler')
      toolbar.add_item(edit_command)
      toolbar.add_item(finish_command)
      toolbar.show()
      file_loaded(__FILE__)
    end

  end
end
