# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module EditorControl
          def begin_editing
            @editor_session.begin_editing()
          end

          def finish_editing
            @finishing_editing = true
            @editor_session.finish()
          ensure
            @finishing_editing = false
          end

          def request_finish_editing
            puts '[IndoorGML] EditModeDialog#RequestfinishEditing'
            result = UI.messagebox("CellSpace 편집을 종료하시겠습니까?", MB_YESNO)
            return false unless result == IDYES

            finish_editing
            return true
          end

          def editing?
            @editor_session.editing?()
          end

          def dual_overlay_visible?
            @editor_session.dual_overlay_visible?()
          end

          def toggle_dual_overlay_visible
            @editor_session.toggle_dual_overlay_visible()
          end

          def set_overlay_min_radius_pixels(radius_pixels)
            radius_pixels = radius_pixels.to_f
            return false unless radius_pixels.positive?

            set_overlay_radius_pixel_range(radius_pixels, @overlay_max_radius_pixels)
          end

          def set_overlay_radius_pixel_range(min_radius_pixels, max_radius_pixels)
            begin
              min_radius_pixels = min_radius_pixels.to_f
              max_radius_pixels = max_radius_pixels.to_f
              return false unless min_radius_pixels.positive? && max_radius_pixels.positive?

              min_radius_pixels, max_radius_pixels = [min_radius_pixels, max_radius_pixels].sort
              @overlay_min_radius_pixels = min_radius_pixels
              @overlay_max_radius_pixels = max_radius_pixels
              Sketchup.active_model().active_view().invalidate() if Sketchup.active_model&.active_view
              true
            rescue StandardError => e
              puts "[IndoorGML] Overlay radius range update failed: #{e.class}: #{e.message}"
              false
            end
          end

          def clear_all_indoor_gml_elements
            model = Sketchup.active_model()
            confirmed = UI.messagebox(
              'Clear all IndoorGML elements?',
              MB_YESNO
            )
            return false unless confirmed == IDYES

            model.start_operation('Clear All IndoorGML Elements', true)
            begin
              @editor_session.finish() if editing?
              clear_indoor_gml_groups()
              reset_runtime_collections()
              model.active_view.invalidate if model&.active_view
              model.commit_operation
              true
            rescue StandardError => e
              model.abort_operation
              puts "[IndoorGML] Clear all failed: #{e.class}: #{e.message}"
              false
            end
          end

          def active_path_changed(model)
            @editor_session.active_path_changed(model)
          end

          def cleanup_before_quit
            @editor_session.cleanup_before_quit()
          end

          def attach_edit_selection_observer(model = Sketchup.active_model)
            begin
              return unless model&.selection
              return if @selection_observed_model_id == model.object_id

              model.selection.add_observer(@selection_observer)
              @selection_observed_model_id = model.object_id
            rescue StandardError => e
              puts "[IndoorGML] Selection observer attach failed: #{e.class}: #{e.message}"
            end
          end

          def detach_edit_selection_observer(model = Sketchup.active_model)
            begin
              return unless model&.selection
              return unless @selection_observed_model_id == model.object_id

              model.selection.remove_observer(@selection_observer)
              @selection_observed_model_id = nil
            rescue StandardError => e
              puts "[IndoorGML] Selection observer detach failed: #{e.class}: #{e.message}"
            end
          end

          def selection_changed
            @editor_session.selection_changed()
          end

          def selected_cell_space_snapshot
            begin
              cell_space = selected_cell_space || @editor_session.editing_cell_space
              return nil unless cell_space&.valid?

              group = cell_space.sketchup_group
              {
                feature: 'CellSpace',
                id: cell_space.id,
                name: group&.name.to_s,
                cell_type: CellSpaceType.label(cell_space.cell_type),
                category_code: cell_space.category_code,
                classification: CellSpaceCategory.selection_value(cell_space.cell_type, cell_space.category_code),
                cell_geometry_editing: @editor_session.cell_space_geometry_editing?
              }
            rescue StandardError => e
              puts "[IndoorGML] Selected CellSpace snapshot failed: #{e.class}: #{e.message}"
              nil
            end
          end

          def set_selected_cell_space_type(cell_type_label, category_code = nil)
            begin
              cell_space = selected_cell_space
              return false unless cell_space&.valid?

              model = Sketchup.active_model()
              operation_started = false
              model.start_operation('Change CellSpace Type and Category', true)
              operation_started = true
              cell_type = CellSpaceType.from_label(cell_type_label)
              category_code = nil unless CellSpaceCategory.valid_for_type?(cell_type, category_code)
              change_cell_space_type(cell_space.sketchup_group, cell_type, category_code)
              model.commit_operation()
              @editor_session.selection_changed()
              model.active_view().invalidate() if model&.active_view
              true
            rescue StandardError => e
              model.abort_operation() if operation_started
              puts "[IndoorGML] Selected CellSpace type update failed: #{e.class}: #{e.message}"
              false
            end
          end

          def set_selected_cell_space_classification(selection_value)
            cell_type, category_code = CellSpaceCategory.parse_selection_value(selection_value)
            set_selected_cell_space_type(CellSpaceType.label(cell_type), category_code)
          end

          def edit_selected_cell_space_geometry
            begin
              cell_space = selected_cell_space
              return false unless cell_space&.valid?

              @editor_session.edit_cell_space_geometry(cell_space)
            rescue StandardError => e
              puts "[IndoorGML] Selected CellSpace geometry edit failed: #{e.class}: #{e.message}"
              false
            end
          end

          def finish_cell_space_geometry_editing
            @editor_session.finish_cell_space_geometry_editing()
          end

          def with_active_path_enforcement_suspended
            @editor_session.with_active_path_enforcement_suspended { yield }
          end

          private

          def apply_indoor_lock_policy
            @editor_session.apply_lock_policy()
          end

          def selected_cell_space
            selection = Sketchup.active_model&.selection
            return nil unless selection

            selection.each do |entity|
              cell_space = find_cell_space_for_entity(entity)
              return cell_space if cell_space&.valid?
            end
            nil
          end
        end
      end
    end
  end
end
