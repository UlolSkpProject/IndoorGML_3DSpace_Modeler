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
            @editor_session.finish()
          end

          def editing?
            @editor_session.editing?()
          end

          def state_radius
            State.display_radius
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

          def set_state_radius(radius)
            radius = radius.to_f
            return false unless radius.positive?

            model = Sketchup.active_model()
            model.start_operation('Set IndoorGML State Radius', true)
            begin
              State.display_radius = radius
              @states.each do |state|
                next unless state&.valid?

                state.apply_radius(radius)
                write_state_attributes(state)
              end
              @transitions.each do |transition|
                next unless transition&.valid?

                update_transition(transition)
                write_transition_attributes(transition)
              end
              model.active_view.invalidate if model&.active_view
              model.commit_operation
              true
            rescue StandardError => e
              model.abort_operation
              puts "[IndoorGML] State radius update failed: #{e.class}: #{e.message}"
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
              cell_space = selected_cell_space
              return nil unless cell_space&.valid?

              group = cell_space.sketchup_group
              {
                feature: 'CellSpace',
                id: cell_space.id,
                name: group&.name.to_s,
                cell_type: CellSpaceType.label(cell_space.cell_type)
              }
            rescue StandardError => e
              puts "[IndoorGML] Selected CellSpace snapshot failed: #{e.class}: #{e.message}"
              nil
            end
          end

          def set_selected_cell_space_type(cell_type_label)
            begin
              cell_space = selected_cell_space
              return false unless cell_space&.valid?

              model = Sketchup.active_model()
              operation_started = false
              model.start_operation('Change CellSpace Type', true)
              operation_started = true
              change_cell_space_type(cell_space.sketchup_group, CellSpaceType.from_label(cell_type_label))
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
