# frozen_string_literal: true

require_relative '../ui_feedback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module DisplayCommands
        def begin_indoor_gml_editing
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          begin
            indoor_model = IndoorModel.current
            if indoor_model.editing?()
              UiFeedback.defer_modal('IndoorGML editing is already active.')
            elsif !indoor_model.begin_editing()
              UiFeedback.defer_modal('IndoorGML PrimalSpaceFeatures group was not found.')
            end
          rescue StandardError => e
            UiFeedback.defer_modal("IndoorGML editing failed:\n#{e.message}")
          end
        end

        def finish_indoor_gml_editing
          begin
            unless IndoorModel.current.finish_editing()
              UiFeedback.defer_modal('IndoorGML editing is not active.')
            end
          rescue StandardError => e
            UiFeedback.defer_modal("IndoorGML editing finish failed:\n#{e.message}")
          end
        end

        def toggle_indoor_gml_editing
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

          begin
            indoor_model = IndoorModel.current
            if indoor_model.editing?()
              finish_indoor_gml_editing()
            else
              begin_indoor_gml_editing()
            end
          rescue StandardError => e
            UiFeedback.defer_modal("IndoorGML editing toggle failed:\n#{e.message}")
          end
        end

        def update_dual_overlay_command
          return unless @dual_overlay_command

          if IndoorModel.current.dual_overlay_visible?
            @dual_overlay_command.menu_text = SeoulSpacePluginsMenu.text(
              'Hide State/Link Overlay',
              '그래프 숨기기'
            )
            description = SeoulSpacePluginsMenu.text(
              'Hide the State/Transition Graph.',
              'State/Transition Graph를 숨깁니다.'
            )
            @dual_overlay_command.tooltip = description
            @dual_overlay_command.status_bar_text = description
          else
            @dual_overlay_command.menu_text = SeoulSpacePluginsMenu.text(
              'Show State/Link Overlay',
              '그래프 보이기'
            )
            description = SeoulSpacePluginsMenu.text(
              'Show the State/Transition Graph.',
              'State/Transition Graph를 표시합니다.'
            )
            @dual_overlay_command.tooltip = description
            @dual_overlay_command.status_bar_text = description
          end
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay command update failed: #{e.class}: #{e.message}"
        end

        def update_geometry_command
          return unless @geometry_command

          if IndoorModel.current.geometry_visible?
            @geometry_command.menu_text = SeoulSpacePluginsMenu.text(
              'Hide Geometry',
              'Geometry숨기기'
            )
            description = SeoulSpacePluginsMenu.text(
              'Hide Geometry.',
              'Geometry를 숨깁니다.'
            )
            @geometry_command.tooltip = description
            @geometry_command.status_bar_text = description
          else
            @geometry_command.menu_text = SeoulSpacePluginsMenu.text(
              'Show Geometry',
              'Geometry보이기'
            )
            description = SeoulSpacePluginsMenu.text(
              'Show Geometry.',
              'Geometry를 표시합니다.'
            )
            @geometry_command.tooltip = description
            @geometry_command.status_bar_text = description
          end
        rescue StandardError => e
          Logger.puts "[IndoorGML] Geometry command update failed: #{e.class}: #{e.message}"
        end

        def toggle_dual_overlay
          IndoorModel.current.toggle_dual_overlay_visible()
          update_dual_overlay_command()
        rescue StandardError => e
          UiFeedback.defer_modal("State/Link overlay toggle failed:\n#{e.message}")
        end

        def open_dual_overlay_scale_dialog
          @dual_overlay_scale_dialog ||= DualOverlayScaleDialog.new
          @dual_overlay_scale_dialog.show
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay scale dialog failed: #{e.class}: #{e.message}"
          UiFeedback.defer_modal("State/Link overlay scale dialog failed:\n#{e.message}")
        end

        def toggle_geometry
          IndoorModel.current.toggle_geometry_visible()
          update_geometry_command()
        rescue StandardError => e
          UiFeedback.defer_modal("Geometry toggle failed:\n#{e.message}")
        end

        def add_context_menu_items(menu)
          indoor_model = IndoorModel.current
          selected_indoor_entities = selected_indoor_gml_entities()
          selected_cell_spaces = selected_indoor_entities.select { |entity| indoor_feature(entity) == 'CellSpace' }

          if !indoor_model.editing?() && selected_indoor_entities.any?()
            menu.add_item('Edit IndoorGML') { begin_indoor_gml_editing() } unless validation_operation_running?
          end

          if indoor_model.editing?() && !validation_operation_running? && cell_space_type_change_available?(selected_cell_spaces)
            menu.add_item('Change CellSpace Type') { change_selected_cell_space_type() }
          end

          if !validation_operation_running? && vertex_normalize_context_target?
            indoor_menu = menu.add_submenu('IndoorGML 3D Modeler')
            indoor_menu.add_item('Vertex Normalize') { vertex_normalize_selected_cell_space() }
          end
        rescue StandardError => e
          Logger.puts "[IndoorGML] Context menu failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
