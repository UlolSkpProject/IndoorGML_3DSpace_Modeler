require 'sketchup.rb'

module ULOL
  include Sketchup
  include Geom
  module Indoor3DGmlModeler

    require_relative 'utils/logger'
    require_relative 'utils/change_snapshot'
    require_relative 'utils/geometry'
    require_relative 'utils/transformation'
    require_relative 'utils/materials'
    require_relative 'utils/hermite_spline'
    require_relative 'domain/abstract_feature'
    require_relative 'domain/cell_space_type'
    require_relative 'domain/cell_space_category'
    require_relative 'domain/navigation_semantic'
    require_relative 'domain/storey'
    require_relative 'domain/cell_space'
    require_relative 'domain/state'
    require_relative 'domain/transition'
    require_relative 'integration/tag_cell_space_adapter'
    require_relative 'infrastructure/observers/observer_helpers'
    require_relative 'infrastructure/observers/cell_space_observer'
    require_relative 'infrastructure/observers/space_features_observer'
    require_relative 'infrastructure/observers/root_entities_observer'
    require_relative 'infrastructure/observers/primal_entities_observer'
    require_relative 'infrastructure/observers/selection_observer'
    require_relative 'infrastructure/observers/model_observer'
    require_relative 'infrastructure/observers/app_observer'
    require_relative 'infrastructure/persistence/attribute_serializer'
    require_relative 'infrastructure/persistence/runtime_restorer'
    require_relative 'application/storey_filter_parser'
    require_relative 'application/storey_filter_options_builder'
    require_relative 'infrastructure/scene/scene_group_guard'
    require_relative 'infrastructure/scene/entity_copy_helper'
    require_relative 'infrastructure/scene/active_path_controller'
    require_relative 'infrastructure/scene/editor_session'
    require_relative 'application/feature_registry'
    require_relative 'application/adjacency_service'
    require_relative 'application/indoor_model/runtime_support'
    require_relative 'application/indoor_model/scene_groups'
    require_relative 'application/indoor_model/feature_lifecycle'
    require_relative 'application/indoor_model/topology'
    require_relative 'application/indoor_model/observer_routing'
    require_relative 'application/indoor_model/entity_relocation'
    require_relative 'application/indoor_model/primal_normalization'
    require_relative 'application/indoor_model/edit_mode_selection_projection'
    require_relative 'application/indoor_model/editor_control'
    require_relative 'application/indoor_model'
    require_relative 'export/gml_exporter'
    require_relative 'export/val3dity_runner'
    require_relative 'ui/commands/conversion_message_formatter'
    require_relative 'ui/edit_mode_overlay'
    require_relative 'ui/edit_mode_dialog'
    require_relative 'ui/export_progress_dialog'
    require_relative 'ui/command_dispatcher'

    module IndoorCore
      def self.tag_cell_space_type_and_category(entity)
        TagCellSpaceAdapter.cell_space_type_and_category(entity)
      end

      def self.resolve_cell_space_type_and_category(entity, cell_type, category_code)
        TagCellSpaceAdapter.resolve_cell_space_type_and_category(entity, cell_type, category_code)
      end

      def self.tag_assigned?(entity)
        TagCellSpaceAdapter.tag_assigned?(entity)
      end
    end

    def self.attach_model_observer
      begin
        @app_observer ||= IndoorCore::Indoor3DGmlAppObserver.new
        Sketchup.add_observer(@app_observer)
        @app_observer.register_model(Sketchup.active_model())
        IndoorCore::IndoorModel.current.refresh_runtime_data()
      rescue StandardError => e
        IndoorCore::Logger.puts "[IndoorGML] Model observer setup failed: #{e.class}: #{e.message}"
      end
    end

    def self.tag_cell_space_type_and_category(entity)
      IndoorCore.tag_cell_space_type_and_category(entity)
    end

    def self.command_dispatcher
      @command_dispatcher ||= IndoorCore::CommandDispatcher.new
    end

    def self.create_command(label, tooltip, icon: nil, &block)
      command = UI::Command.new(label) { block.call() }
      command.tooltip = tooltip
      command.status_bar_text = tooltip
      assign_command_icon(command, icon) if icon
      command
    end

    def self.assign_command_icon(command, icon)
      path = icon_path(icon)
      return unless File.exist?(path)

      command.small_icon = path
      command.large_icon = path
    rescue StandardError => e
      IndoorCore::Logger.puts "[IndoorGML] Command icon failed: #{e.class}: #{e.message}"
    end

    def self.icon_path(filename)
      File.join(__dir__, 'assets', 'icons', filename)
    end


    unless file_loaded?(__FILE__)
      attach_model_observer()
      dispatcher = command_dispatcher
      menu = UI.menu('Extensions').add_submenu('Indoor3DGML Modeler')

      create_cell_space_command = create_command(
        'Create CellSpace',
        'Convert selected solid groups to CellSpace',
        icon: 'create_cellspace.svg'
      ) do
        dispatcher.convert_selected_solid_groups_to_cell_spaces()
      end
      create_cell_space_command.set_validation_proc do
        dispatcher.validation_operation_running? ? MF_GRAYED : MF_ENABLED
      end
      change_type_command = create_command(
        'Change CellSpace Type',
        'Change selected CellSpace type',
        icon: 'change_cellspace_type.svg'
      ) do
        dispatcher.change_selected_cell_space_type()
      end
      change_type_command.set_validation_proc do
        indoor_model = IndoorCore::IndoorModel.current
        selected_cell_spaces = dispatcher.selected_indoor_gml_entities.select do |entity|
          dispatcher.indoor_feature(entity) == 'CellSpace'
        end
      
        indoor_model.editing? && dispatcher.cell_space_type_change_available?(selected_cell_spaces) ? MF_ENABLED : MF_GRAYED
      end
      @edit_property_command = create_command(
        'Edit CellSpace Property',
        'Toggle IndoorGML editing',
        icon: 'edit_cellspace_property.svg'
      ) do
        dispatcher.toggle_indoor_gml_editing()
      end

      @edit_property_command.set_validation_proc do
        next MF_GRAYED if dispatcher.validation_operation_running?

        IndoorCore::IndoorModel.current.editing? ? MF_CHECKED : MF_UNCHECKED
      end
      @geometry_command = create_command(
        'Show Geometry',
        'Show CellSpace geometry',
        icon: 'toggle_geometry.svg'
      ) do
        dispatcher.toggle_geometry()
      end
      dispatcher.geometry_command = @geometry_command
      @geometry_command.set_validation_proc do
        dispatcher.update_geometry_command()
        IndoorCore::IndoorModel.current.geometry_visible? ? MF_CHECKED : MF_UNCHECKED
      end
      @dual_overlay_command = create_command(
        'Show State/Link Overlay',
        'Show State and Transition overlay',
        icon: 'toggle_dual_overlay.svg'
      ) do
        dispatcher.toggle_dual_overlay()
      end
      dispatcher.dual_overlay_command = @dual_overlay_command
      @dual_overlay_command.set_validation_proc do
        dispatcher.update_dual_overlay_command()
        IndoorCore::IndoorModel.current.dual_overlay_visible? ? MF_CHECKED : MF_UNCHECKED
      end
      export_command = create_command(
        'Export GML',
        'Export GML without validity check',
        icon: 'export_gml.svg'
      ) do
        dispatcher.export_gml()
      end
      export_command.set_validation_proc do
        dispatcher.validation_operation_running? ? MF_GRAYED : MF_ENABLED
      end
      check_validity_command = create_command(
        'Check Validity',
        'Create temp GML and run validity check',
        icon: 'check_validity.svg'
      ) do
        dispatcher.check_validity()
      end
      check_validity_command.set_validation_proc do
        dispatcher.validation_operation_running? ? MF_GRAYED : MF_ENABLED
      end
      dispatcher.update_geometry_command()
      dispatcher.update_dual_overlay_command()

      menu.add_item(create_cell_space_command)
      menu.add_item(@edit_property_command)
      menu.add_item(change_type_command)
      menu.add_item(@geometry_command)
      menu.add_item(@dual_overlay_command)
      menu.add_item(export_command)
      menu.add_item(check_validity_command)

      UI.add_context_menu_handler do |context_menu|
        dispatcher.add_context_menu_items(context_menu)
      end

      toolbar = UI::Toolbar.new('Indoor3DGML Modeler')
      toolbar.add_separator
      toolbar.add_item(create_cell_space_command)
      toolbar.add_item(@edit_property_command)
      toolbar.add_item(change_type_command)
      toolbar.add_separator
      toolbar.add_item(@geometry_command)
      toolbar.add_item(@dual_overlay_command)
      toolbar.add_separator
      toolbar.add_item(export_command)
      toolbar.add_item(check_validity_command)
      toolbar.add_separator
      toolbar.show()
      file_loaded(__FILE__)
    end

  end
end
