# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module DisplayCommands
        def begin_indoor_gml_editing
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

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
          return if respond_to?(:validation_operation_running?) && validation_operation_running?

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

        def open_dual_overlay_scale_dialog
          @dual_overlay_scale_dialog ||= DualOverlayScaleDialog.new
          @dual_overlay_scale_dialog.show
        rescue StandardError => e
          Logger.puts "[IndoorGML] Dual overlay scale dialog failed: #{e.class}: #{e.message}"
          UI.messagebox("State/Link overlay scale dialog failed:\n#{e.message}")
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
            menu.add_item('Edit IndoorGML') { begin_indoor_gml_editing() } unless validation_operation_running?
          end

          if indoor_model.editing?() && !validation_operation_running? && cell_space_type_change_available?(selected_cell_spaces)
            menu.add_item('Change CellSpace Type') { change_selected_cell_space_type() }
          end
        rescue StandardError => e
          Logger.puts "[IndoorGML] Context menu failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
