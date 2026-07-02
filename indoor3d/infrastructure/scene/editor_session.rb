# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditorSession
        require_relative 'editor_session/lock_controller'
        require_relative 'editor_session/batch_progress'
        require_relative 'editor_session/visibility_controller'
        require_relative 'editor_session/overlay_controller'
        require_relative 'editor_session/validation_focus_controller'
        require_relative 'editor_session/edit_active_path_controller'
        include BatchProgress

        GRAPH_VISIBLE_ATTRIBUTE = 'graph_visible'
        GEOMETRY_VISIBLE_ATTRIBUTE = 'geometry_visible'

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @editing = false
          @dialog = EditModeDialog.new(@indoor_model)
          @progress = nil
          @dual_overlay_visible = model_boolean_attribute(GRAPH_VISIBLE_ATTRIBUTE, true)
          @geometry_visible = model_boolean_attribute(GEOMETRY_VISIBLE_ATTRIBUTE, true)
          @validation_focus_controller = ValidationFocusController.new
          @lock_controller = LockController.new(indoor_model: @indoor_model)
          @visibility_controller = VisibilityController.new
          @overlay_controller = OverlayController.new(indoor_model: @indoor_model)
          @active_path_controller = EditActivePathController.new(
            indoor_model: @indoor_model,
            on_lock: -> { apply_lock_policy },
            on_selection: -> { selection_changed },
            on_invalidate: ->(model) { invalidate_view(model) }
          )
        end

        def editing?
          @editing
        end

        def dual_overlay_visible?
          @dual_overlay_visible == true
        end

        def toggle_dual_overlay_visible
          set_dual_overlay_visible(!dual_overlay_visible?)
        end

        def set_dual_overlay_visible(visible)
          @dual_overlay_visible = visible == true
          write_model_boolean_attribute(GRAPH_VISIBLE_ATTRIBUTE, @dual_overlay_visible)
          model = Sketchup.active_model()
          ensure_overlay_registered(model) if @dual_overlay_visible
          update_overlay_enabled()
          invalidate_view(model)
          @dual_overlay_visible
        end

        def geometry_visible?
          @geometry_visible != false
        end

        def toggle_geometry_visible
          set_geometry_visible(!geometry_visible?)
        end

        def set_geometry_visible(visible)
          @geometry_visible = visible == true
          write_model_boolean_attribute(GEOMETRY_VISIBLE_ATTRIBUTE, @geometry_visible)
          apply_geometry_visibility()
          @geometry_visible
        end

        def apply_display_state
          set_dual_overlay_visible(dual_overlay_visible?)
          apply_geometry_visibility()
        end

        def begin_editing
          return false if @editing
          model = Sketchup.active_model()

          # @indoor_model.refresh_runtime_data()
          primal_group = @indoor_model.primal_group
          return false unless primal_group&.valid?()

          ensure_overlay_registered(model)
          active_path_controller.remember_current_path(model)
          reset_edit_mode_visibility_filter
          @editing = true
          @indoor_model.attach_edit_selection_observer(model)
          activated = false
          @indoor_model.with_space_feature_constraint do
            apply_lock_policy()
            activated = activate_edit_context(model, [primal_group])
          end
          unless activated
            @editing = false
            active_path_controller.reset_target
            @indoor_model.detach_edit_selection_observer(model)
            apply_lock_policy()
            return false
          end
          @dialog.show()
          selection_changed()
          invalidate_view(model)
          true
        end

        def begin_validation_focus_editing(cell_gml_ids)
          ids = Array(cell_gml_ids).map(&:to_s).reject(&:empty?)
          return false if ids.empty?

          validation_focus_controller.begin(ids)
          capture_and_apply_validation_focus_rendering_options(ids.length)
          started = @editing ? true : begin_editing
          unless started
            restore_validation_focus_rendering_options
            clear_validation_focus
            return false
          end

          apply_validation_focus_visibility
          invalidate_overlay_transition_points
          selection_changed
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus edit mode failed: #{e.class}: #{e.message}"
          clear_validation_focus
          false
        end

        def finish
          return false unless @editing

          model = Sketchup.active_model()
          with_active_path_enforcement_suspended do
            active_path_controller.prepare_for_finish(model)
            restore_validation_focus_visibility
            normalize_visibility_for_non_edit_mode
            @editing = false
            active_path_controller.reset_target
            reset_edit_mode_visibility_filter
            restore_validation_focus_rendering_options
            clear_validation_focus
            @indoor_model.detach_edit_selection_observer(model)
            active_path_controller.close(model)
            active_path_controller.clear_previous_path
            update_overlay_enabled()
            @dialog.close()
            apply_lock_policy()
            apply_geometry_visibility()
            invalidate_view(model)
            true
          end
        end

        def lock_entity(entity)
          lock_controller.lock_entity(entity)
        end

        def unlock_entity(entity)
          lock_controller.unlock_entity(entity)
        end

        def with_unlocked(entity)
          lock_controller.with_unlocked(entity) { yield }
        end

        def apply_lock_policy
          lock_controller.apply(editing: @editing)
        end

        def validation_focus_active?
          validation_focus_controller.active?
        end

        def visible_storeys
          visibility_controller.visible_storeys
        end

        def visible_cell_type_labels
          visible_cell_types.map { |cell_type| CellSpaceType.label(cell_type) }
        end

        def set_visibility_filter(storeys:, cell_types:)
          visibility_controller.set_filter(
            storeys: normalize_storey_filter(storeys),
            cell_types: normalize_cell_type_filter(cell_types)
          )
          invalidate_overlay_transition_points
          apply_edit_mode_visibility_filter
          selection_changed
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit visibility filter update failed: #{e.class}: #{e.message}"
          false
        end

        def refresh_visibility_filter
          invalidate_overlay_transition_points
          apply_edit_mode_visibility_filter
        end

        def dual_overlay_state_visible?(state)
          return false unless state&.valid?

          edit_mode_visible_cell_space?(state.duality_cell)
        rescue StandardError
          false
        end

        def dual_overlay_transition_visible?(transition)
          return false unless transition&.valid?
          return false unless transition.state1&.valid? && transition.state2&.valid?

          dual_overlay_state_visible?(transition.state1) ||
            dual_overlay_state_visible?(transition.state2)
        rescue StandardError
          false
        end

        def validation_focus_cell_space?(cell_space)
          return true unless validation_focus_active?
          return false unless cell_space&.valid?

          validation_focus_controller.focus_cell_space?(cell_space)
        rescue StandardError
          false
        end

        def validation_focus_state?(state)
          return true unless validation_focus_active?

          validation_visible_cell_space?(state&.duality_cell)
        rescue StandardError
          false
        end

        def set_validation_focus_highlight(cell_gml_ids, code = nil)
          validation_focus_controller.set_highlight(cell_gml_ids, code)
          apply_validation_focus_visibility
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus highlight failed: #{e.class}: #{e.message}"
          false
        end

        def validation_focus_highlight_cell_spaces
          validation_focus_controller.highlight_cell_spaces(@indoor_model.cell_spaces)
        rescue StandardError
          []
        end

        def validation_focus_highlight_code
          validation_focus_controller.highlight_code
        end

        def validation_focus_elements
          validation_focus_controller.elements(
            cell_spaces: @indoor_model.cell_spaces,
            transitions: @indoor_model.transitions
          )
        rescue StandardError
          { cell_spaces: [], states: [], transitions: [] }
        end

        def cell_space_geometry_editing?
          active_path_controller.cell_space_geometry_editing?(editing: @editing)
        end

        def editing_cell_space
          active_path_controller.editing_cell_space
        end

        def edit_cell_space_geometry(cell_space)
          begin
            return false unless @editing
            return false unless cell_space&.valid?

            primal_group = @indoor_model.primal_group
            group = cell_space.sketchup_group
            return false unless primal_group&.valid? && group&.valid?

            model = Sketchup.active_model()
            target_path = [primal_group, group]
            active_path_controller.set_target_path(target_path)
            mark_editable_primal_entities()
            apply_lock_policy()
            active_path_controller.set(model, target_path)
            selection_changed()
            invalidate_view(model)
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace geometry edit activation failed: #{e.class}: #{e.message}"
            false
          end
        end

        def finish_cell_space_geometry_editing
          begin
            return false unless @editing
            return false unless cell_space_geometry_editing?

            primal_group = @indoor_model.primal_group
            return false unless primal_group&.valid?

            model = Sketchup.active_model()
            active_path_controller.set_target_path([primal_group])
            active_path_controller.set(model, [primal_group])
            selection_changed()
            invalidate_view(model)
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] CellSpace geometry edit finish failed: #{e.class}: #{e.message}"
            false
          end
        end

        def apply_geometry_visibility
          primal_group = @indoor_model.primal_group
          return false unless primal_group&.valid?
          return false unless primal_group.respond_to?(:visible=)

          with_visibility_update_operation do
            with_unlocked(primal_group) do
              primal_group.visible = geometry_visible?
            end
          end
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Geometry visibility update failed: #{e.class}: #{e.message}"
          false
        end

        def apply_validation_focus_visibility
          return false unless validation_focus_active?

          with_visibility_update_operation do
            @indoor_model.cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              group = cell_space.sketchup_group
              next unless cell_space_visibility_target?(group)

              persistent_id = group.persistent_id
              unless validation_focus_controller.visibility_snapshot?(persistent_id)
                validation_focus_controller.remember_visibility_snapshot(
                  persistent_id,
                  capture_cell_space_visibility(group)
                )
              end
              with_unlocked(group) do
                set_cell_space_render_visible(
                  group,
                  edit_mode_visible_cell_space?(cell_space),
                  validation_focus_controller.visibility_snapshot(persistent_id)
                )
              end
            end
          end
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus visibility failed: #{e.class}: #{e.message}"
          false
        end

        def validation_visible_cell_space?(cell_space)
          return true unless validation_focus_active?
          return false unless cell_space&.valid?
          validation_focus_controller.visible_cell_space?(cell_space)
        rescue StandardError
          false
        end

        def restore_validation_focus_visibility
          snapshots = validation_focus_controller.visibility_snapshots
          return true if snapshots.empty?

          with_visibility_update_operation do
            @indoor_model.cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              group = cell_space.sketchup_group
              next unless cell_space_visibility_target?(group)
              next unless snapshots.key?(group.persistent_id)

              with_unlocked(group) { restore_cell_space_visibility(group, snapshots[group.persistent_id]) }
            end
          end
          validation_focus_controller.clear_visibility_snapshots
          apply_edit_mode_visibility_filter(ignore_validation: true) if visibility_filter_active?
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus visibility restore failed: #{e.class}: #{e.message}"
          false
        end

        def clear_validation_focus
          validation_focus_controller.clear
        end

        def apply_edit_mode_visibility_filter(ignore_validation: false)
          unless visibility_filter_active? || (!ignore_validation && validation_focus_active?)
            return apply_all_edit_mode_cell_space_visibility
          end

          with_visibility_update_operation do
            @indoor_model.cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              group = cell_space.sketchup_group
              next unless cell_space_visibility_target?(group)

              remember_edit_mode_visibility(group) if visibility_filter_active?
              with_unlocked(group) do
                set_cell_space_render_visible(
                  group,
                  edit_mode_visible_cell_space?(cell_space, include_validation: !ignore_validation),
                  visibility_controller.edit_mode_visibility_snapshot(group)
                )
              end
            end
          end
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit visibility filter apply failed: #{e.class}: #{e.message}"
          false
        end

        def apply_all_edit_mode_cell_space_visibility
          with_visibility_update_operation do
            @indoor_model.cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              group = cell_space.sketchup_group
              next unless cell_space_visibility_target?(group)

              snapshot = visibility_controller.edit_mode_visibility_snapshot(group)
              with_unlocked(group) do
                snapshot ? restore_cell_space_visibility(group, snapshot) : set_cell_space_render_visible(group, true)
              end
            end
          end
          visibility_controller.clear_edit_mode_snapshots
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit visibility filter clear failed: #{e.class}: #{e.message}"
          false
        end

        def restore_edit_mode_visibility
          return true if visibility_controller.edit_mode_visibility_snapshots_empty?

          with_visibility_update_operation do
            @indoor_model.cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              group = cell_space.sketchup_group
              next unless cell_space_visibility_target?(group)
              next unless visibility_controller.edit_mode_visibility_snapshot?(group)

              snapshot = visibility_controller.edit_mode_visibility_snapshot(group)
              with_unlocked(group) { restore_cell_space_visibility(group, snapshot) }
            end
          end
          visibility_controller.clear_edit_mode_snapshots
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit visibility filter restore failed: #{e.class}: #{e.message}"
          false
        end

        def normalize_visibility_for_non_edit_mode
          apply_all_edit_mode_cell_space_visibility
          apply_geometry_visibility
          invalidate_overlay_transition_points
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit visibility normalize failed: #{e.class}: #{e.message}"
          false
        end

        def capture_and_apply_validation_focus_rendering_options(focus_cell_count)
          return unless focus_cell_count.to_i >= 2

          validation_focus_controller.capture_and_apply_rendering_options(Sketchup.active_model, focus_cell_count)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus rendering option update failed: #{e.class}: #{e.message}"
        end

        def restore_validation_focus_rendering_options
          validation_focus_controller.restore_rendering_options(Sketchup.active_model)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus rendering option restore failed: #{e.class}: #{e.message}"
        end

        def active_path_changed(model)
          active_path_controller.active_path_changed(
            model,
            editing: @editing,
            reenter: -> { reenter_editing_from_primal_path }
          )
        end

        def with_active_path_enforcement_suspended
          active_path_controller.with_suspended_enforcement { yield }
        end

        def selection_changed
          return unless @editing

          @dialog.update_selection(@indoor_model.selected_edit_mode_snapshot)
        end

        def cleanup_before_quit
          begin
            @dialog.close()
            finish() if @editing
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit shutdown cleanup failed: #{e.class}: #{e.message}"
          end
        end

        def close_dialog_only
          begin
            @dialog.close_without_finish()
            restore_validation_focus_visibility
            @editing = false
            active_path_controller.reset
            restore_validation_focus_rendering_options
            restore_edit_mode_visibility
            reset_edit_mode_visibility_filter
            clear_validation_focus
            @progress = nil
            set_overlay_enabled(false)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit model close cleanup failed: #{e.class}: #{e.message}"
          end
        end

        def invalidate_overlay_transition_points
          overlay_controller.invalidate_transition_points
        end

        def recover_unlocked_primal_after_transaction(model)
          active_path_controller.recover_unlocked_primal_after_transaction(
            model,
            editing: @editing,
            reenter: -> { reenter_editing_from_primal_path }
          )
        end

        private

        def visible_cell_types
          visibility_controller.visible_cell_types
        end

        def lock_controller
          @lock_controller ||= LockController.new(indoor_model: @indoor_model)
        end

        def visibility_controller
          @visibility_controller ||= VisibilityController.new
        end

        def overlay_controller
          @overlay_controller ||= OverlayController.new(indoor_model: @indoor_model)
        end

        def validation_focus_controller
          @validation_focus_controller ||= ValidationFocusController.new
        end

        def active_path_controller
          @active_path_controller ||= EditActivePathController.new(
            indoor_model: @indoor_model,
            on_lock: -> { apply_lock_policy },
            on_selection: -> { selection_changed },
            on_invalidate: ->(model) { invalidate_view(model) }
          )
        end

        def with_visibility_update_operation
          model = Sketchup.active_model
          return with_visibility_observer_suppression { yield } unless model

          if model.respond_to?(:active_operation_name) && model.active_operation_name.to_s.length.positive?
            return with_visibility_observer_suppression { yield }
          end

          operation_started = false
          begin
            result = nil
            with_visibility_observer_suppression do
              operation_started = model.start_operation('IndoorGML Edit Visibility', true)
              result = yield
              model.commit_operation if operation_started
              operation_started = false
            end
            result
          rescue StandardError
            model.abort_operation if operation_started
            raise
          end
        end

        def with_visibility_observer_suppression
          if @indoor_model.respond_to?(:with_runtime_observer_suppression)
            @indoor_model.with_runtime_observer_suppression { yield }
          else
            yield
          end
        end

        def cell_space_visibility_target?(group)
          visibility_controller.cell_space_visibility_target?(group)
        end

        def capture_cell_space_visibility(group)
          visibility_controller.capture_cell_space_visibility(group)
        end

        def restore_cell_space_visibility(group, snapshot)
          visibility_controller.restore_cell_space_visibility(group, snapshot)
        end

        def set_cell_space_render_visible(group, visible, snapshot = nil)
          visibility_controller.set_cell_space_render_visible(group, visible, snapshot)
        end

        def reset_edit_mode_visibility_filter
          visibility_controller.reset_filter
        end

        def normalize_storey_filter(values)
          StoreyFilterParser.normalize_labels(values)
        end

        def normalize_cell_type_filter(values)
          Array(values).map do |value|
            label = value.to_s.strip
            next nil if label.empty?

            CellSpaceType::LABELS.value?(label) ? CellSpaceType.from_label(label) : nil
          end.compact.uniq
        end

        def visibility_filter_active?
          visibility_controller.filter_active?
        end

        def remember_edit_mode_visibility(group)
          persistent_id = group.persistent_id
          snapshot = validation_focus_controller.visibility_snapshot(persistent_id) if validation_focus_controller.visibility_snapshot?(persistent_id)
          visibility_controller.remember_edit_mode_visibility(group, snapshot: snapshot)
        rescue StandardError
          nil
        end

        def edit_mode_visible_cell_space?(cell_space, include_validation: true)
          return false if include_validation && !validation_visible_cell_space?(cell_space)
          return false unless storey_filter_visible?(cell_space)
          return false unless cell_type_filter_visible?(cell_space)

          true
        end

        def storey_filter_visible?(cell_space)
          return true if visible_storeys.empty?

          cell_storeys = StoreyFilterParser.labels_for(cell_space&.storey)
          cell_storeys.any? { |storey| visible_storeys.include?(storey) }
        end

        def cell_type_filter_visible?(cell_space)
          return true if visible_cell_types.empty?

          visible_cell_types.include?(cell_space&.cell_type)
        end

        def ensure_overlay_registered(model)
          overlay_controller.ensure_registered(model)
        end

        def set_overlay_enabled(enabled)
          overlay_controller.set_enabled(enabled)
        end

        def update_overlay_enabled
          overlay_controller.update_enabled(
            editing: @editing,
            dual_overlay_visible: @dual_overlay_visible,
            progress_active: progress_active?
          )
        end

        def invalidate_view(model)
          overlay_controller.invalidate_view(model)
        end

        def model_boolean_attribute(key, default)
          model = @indoor_model.model || Sketchup.active_model
          value = model&.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, key)
          if value.nil?
            write_model_boolean_attribute(key, default)
            return default == true
          end

          value == true || value.to_s == 'true'
        rescue StandardError
          default == true
        end

        def write_model_boolean_attribute(key, value)
          model = @indoor_model.model || Sketchup.active_model
          model&.set_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, key, value == true)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Display state write failed: #{e.class}: #{e.message}"
          false
        end

        def activate_edit_context(model, target_path)
          active_path_controller.activate(model, target_path)
        end

        def reenter_editing_from_primal_path
          return false unless begin_editing

          active_path_controller.clear_previous_path
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit mode reentry from primal active path failed: #{e.class}: #{e.message}"
          false
        end

      end

    end
  end
end
