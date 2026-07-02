# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditorSession
        require_relative 'editor_session/lock_controller'
        require_relative 'editor_session/lock_policy'
        require_relative 'editor_session/batch_progress'
        require_relative 'editor_session/visibility_controller'
        require_relative 'editor_session/overlay_controller'
        include LockPolicy
        include BatchProgress

        GRAPH_VISIBLE_ATTRIBUTE = 'graph_visible'
        GEOMETRY_VISIBLE_ATTRIBUTE = 'geometry_visible'

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @editing = false
          @editable_entity_ids = {}
          @dialog = EditModeDialog.new(@indoor_model)
          @previous_active_path = nil
          @editing_active_path_target = nil
          @enforcing_active_path = false
          @active_path_enforcement_suspended = false
          @progress = nil
          @dual_overlay_visible = model_boolean_attribute(GRAPH_VISIBLE_ATTRIBUTE, true)
          @geometry_visible = model_boolean_attribute(GEOMETRY_VISIBLE_ATTRIBUTE, true)
          @validation_focus_cell_ids = nil
          @validation_highlight_cell_ids = nil
          @validation_highlight_code = nil
          @validation_focus_visibility = {}
          @validation_focus_hide_rest_previous = nil
          @lock_controller = LockController.new(indoor_model: @indoor_model)
          @visibility_controller = VisibilityController.new
          @overlay_controller = OverlayController.new(indoor_model: @indoor_model)
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
          @previous_active_path = active_path_snapshot(model)
          reset_edit_mode_visibility_filter
          @editing = true
          @indoor_model.attach_edit_selection_observer(model)
          mark_editable_primal_entities()
          activated = false
          @indoor_model.with_space_feature_constraint do
            apply_lock_policy()
            activated = activate_edit_context(model, [primal_group])
          end
          unless activated
            @editing = false
            @editable_entity_ids = {}
            @editing_active_path_target = nil
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

          @validation_focus_cell_ids = ids.each_with_object({}) { |id, memo| memo[id] = true }
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
            prepare_active_path_for_finish(model)
            restore_validation_focus_visibility
            normalize_visibility_for_non_edit_mode
            @editing = false
            @editable_entity_ids = {}
            @editing_active_path_target = nil
            reset_edit_mode_visibility_filter
            restore_validation_focus_rendering_options
            clear_validation_focus
            @indoor_model.detach_edit_selection_observer(model)
            close_active_path(model)
            @previous_active_path = nil
            update_overlay_enabled()
            @dialog.close()
            apply_lock_policy()
            apply_geometry_visibility()
            invalidate_view(model)
            true
          end
        end

        def editable_entity?(entity)
          begin
            return false unless @editing
            return false unless entity&.valid?()

            @editable_entity_ids[entity.entityID] == true
          rescue StandardError
            false
          end
        end

        def validation_focus_active?
          @validation_focus_cell_ids.is_a?(Hash) && !@validation_focus_cell_ids.empty?
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

          @validation_focus_cell_ids[validation_focus_cell_gml_id(cell_space)] == true
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
          ids = Array(cell_gml_ids).map(&:to_s).reject(&:empty?)
          @validation_highlight_cell_ids = ids.empty? ? nil : ids.each_with_object({}) { |id, memo| memo[id] = true }
          @validation_highlight_code = code.to_s
          apply_validation_focus_visibility
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus highlight failed: #{e.class}: #{e.message}"
          false
        end

        def validation_focus_highlight_cell_spaces
          return [] unless @validation_highlight_cell_ids.is_a?(Hash) && !@validation_highlight_cell_ids.empty?

          @indoor_model.cell_spaces.select do |cell_space|
            cell_space&.valid? && @validation_highlight_cell_ids[validation_focus_cell_gml_id(cell_space)] == true
          end
        rescue StandardError
          []
        end

        def validation_focus_highlight_code
          @validation_highlight_code
        end

        def validation_focus_elements
          cells = validation_focus_cell_spaces
          cell_set = cells.each_with_object({}) { |cell, memo| memo[cell.object_id] = true }
          states = cells.map(&:duality_state).select { |state| state&.valid? }
          transitions = @indoor_model.transitions.select do |transition|
            next false unless transition&.valid?

            cell1 = transition.state1&.duality_cell
            cell2 = transition.state2&.duality_cell
            cell1&.valid? && cell2&.valid? && cell_set[cell1.object_id] && cell_set[cell2.object_id]
          end

          {
            cell_spaces: cells,
            states: states,
            transitions: transitions
          }
        rescue StandardError
          { cell_spaces: [], states: [], transitions: [] }
        end

        def cell_space_geometry_editing?
          @editing && valid_editing_active_path_target().length > 1
        end

        def editing_cell_space
          begin
            target_path = valid_editing_active_path_target()
            return nil unless target_path.length > 1

            target_group = target_path[1]
            @indoor_model.cell_spaces.find do |cell_space|
              cell_space&.valid? && cell_space.sketchup_group == target_group
            end
          rescue StandardError
            nil
          end
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
            @editing_active_path_target = target_path
            mark_editable_primal_entities()
            apply_lock_policy()
            set_active_path(model, target_path)
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
            @editing_active_path_target = [primal_group]
            set_active_path(model, [primal_group])
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
            @validation_focus_visibility ||= {}
            @indoor_model.cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              group = cell_space.sketchup_group
              next unless cell_space_visibility_target?(group)

              persistent_id = group.persistent_id
              unless @validation_focus_visibility.key?(persistent_id)
                @validation_focus_visibility[persistent_id] = capture_cell_space_visibility(group)
              end
              with_unlocked(group) do
                set_cell_space_render_visible(
                  group,
                  edit_mode_visible_cell_space?(cell_space),
                  @validation_focus_visibility[persistent_id]
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

        def validation_focus_cell_spaces
          return [] unless validation_focus_active?

          @indoor_model.cell_spaces.select { |cell_space| validation_focus_cell_space?(cell_space) }
        rescue StandardError
          []
        end

        def validation_visible_cell_space?(cell_space)
          return true unless validation_focus_active?
          return false unless cell_space&.valid?
          if @validation_highlight_cell_ids.is_a?(Hash) && !@validation_highlight_cell_ids.empty?
            return @validation_highlight_cell_ids[validation_focus_cell_gml_id(cell_space)] == true
          end

          validation_focus_cell_space?(cell_space)
        rescue StandardError
          false
        end

        def restore_validation_focus_visibility
          snapshots = @validation_focus_visibility || {}
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
          @validation_focus_visibility = {}
          apply_edit_mode_visibility_filter(ignore_validation: true) if visibility_filter_active?
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus visibility restore failed: #{e.class}: #{e.message}"
          false
        end

        def clear_validation_focus
          @validation_focus_cell_ids = nil
          @validation_highlight_cell_ids = nil
          @validation_highlight_code = nil
          @validation_focus_visibility = {}
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

          options = Sketchup.active_model&.rendering_options
          return unless options

          @validation_focus_hide_rest_previous = options['HideRestOfModel'] if @validation_focus_hide_rest_previous.nil?
          options['HideRestOfModel'] = false
          Sketchup.active_model&.active_view&.invalidate
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus rendering option update failed: #{e.class}: #{e.message}"
        end

        def restore_validation_focus_rendering_options
          return if @validation_focus_hide_rest_previous.nil?

          options = Sketchup.active_model&.rendering_options
          options['HideRestOfModel'] = @validation_focus_hide_rest_previous unless options.nil?
          @validation_focus_hide_rest_previous = nil
          Sketchup.active_model&.active_view&.invalidate
        rescue StandardError => e
          @validation_focus_hide_rest_previous = nil
          IndoorCore::Logger.puts "[IndoorGML] Validation focus rendering option restore failed: #{e.class}: #{e.message}"
        end

        def validation_focus_cell_gml_id(cell_space)
          "cell_#{cell_space.id.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')}"
        end

        def active_path_changed(model)
          begin
            model ||= Sketchup.active_model()
            if !@editing && primal_group_active_path?(model)
              reenter_editing_from_primal_path(model)
              return
            end

            return unless @editing
            return if @enforcing_active_path
            return if @active_path_enforcement_suspended

            enforce_edit_context(model)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit active path enforcement failed: #{e.class}: #{e.message}"
          end
        end

        def with_active_path_enforcement_suspended
          begin
            previous = @active_path_enforcement_suspended
            @active_path_enforcement_suspended = true
            yield
          ensure
            @active_path_enforcement_suspended = previous
          end
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
            @editable_entity_ids = {}
            @editing_active_path_target = nil
            @previous_active_path = nil
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
          begin
            return false if @editing

            primal_group = @indoor_model.primal_group
            return false unless primal_group&.valid?
            return false unless primal_group_active_path?(model || Sketchup.active_model)

            reenter_editing_from_primal_path(model || Sketchup.active_model)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Unlocked primal recovery failed: #{e.class}: #{e.message}"
            false
          end
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

        def visibility_child_entities(group)
          visibility_controller.visibility_child_entities(group)
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
          snapshot = @validation_focus_visibility[persistent_id] if @validation_focus_visibility&.key?(persistent_id)
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

        def active_path_snapshot(model)
          path = model.active_path()
          path ? path.dup : nil
        end

        def activate_edit_context(model, target_path)
          begin
            return false unless model.respond_to?(:active_path=)

            @editing_active_path_target = target_path
            set_active_path(model, target_path)
            true
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit context activation failed: #{e.class}: #{e.message}"
            false
          end
        end

        def enforce_edit_context(model)
          target_path = valid_editing_active_path_target()
          return if target_path.empty?
          return if active_path_matches?(model, target_path)

          current_path = model.active_path
          if current_path.nil?
            set_active_path(model, target_path)
            selection_changed()
            invalidate_view(model)
            return
          end

          # # root 탈출 시 → 종료 확인 : viewport의 빈 곳을 클릭해도 root로 나가지는 issue가 있어서 일단 제외하는 목적으로 주석처리.
          # if current_path.nil? && target_path == [@indoor_model.primal_group]
          #   if @indoor_model.request_finish_editing()
          #     return
          #   else
          #     set_active_path(model, target_path)
          #     return
          #   end
          # end

          # cell 편집 중 primal_group으로 돌아오는 경우 → 허용
          primal_group = @indoor_model.primal_group
          if editing_cell_space_path?(current_path, primal_group)
            @editing_active_path_target = current_path
            mark_editable_primal_entities()
            apply_lock_policy()
            selection_changed()
            invalidate_view(model)
            return
          end

          if current_path == [primal_group] && target_path.length > 1 && target_path.first == primal_group
            @editing_active_path_target = [primal_group]
            apply_lock_policy()
            selection_changed()
            invalidate_view(model)
            return
          end

          set_active_path(model, target_path)
        end

        def valid_editing_active_path_target
          target_path = Array(@editing_active_path_target).select { |entity| entity&.valid?() }
          return target_path unless target_path.empty?

          primal_group = @indoor_model.primal_group
          primal_group&.valid?() ? [primal_group] : []
        end

        def active_path_matches?(model, target_path)
          active_path = model.active_path()
          return false unless active_path && active_path.length == target_path.length

          active_path.each_with_index.all? { |entity, index| entity == target_path[index] }
        end

        def primal_group_active_path?(model)
          primal_group = @indoor_model.primal_group
          return false unless primal_group&.valid?

          active_path_matches?(model, [primal_group])
        end

        def reenter_editing_from_primal_path(model)
          return false unless begin_editing

          @previous_active_path = nil
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit mode reentry from primal active path failed: #{e.class}: #{e.message}"
          false
        end

        def editing_cell_space_path?(path, primal_group)
          return false unless path&.length == 2
          return false unless path.first == primal_group

          cell_group = path.last
          @indoor_model.cell_spaces.any? do |cell_space|
            cell_space&.valid? && cell_space.sketchup_group == cell_group
          end
        rescue StandardError
          false
        end

        def set_active_path(model, target_path)
          begin
            @enforcing_active_path = true
            model.active_path = target_path
          ensure
            @enforcing_active_path = false
          end
        end

        def restore_active_path(model)
          begin
            if @previous_active_path
              valid_path = @previous_active_path.select { |entity| entity&.valid?() }
              if model.respond_to?(:active_path=) && !valid_path.empty?()
                model.active_path = valid_path
                return
              end
            end

            model.close_active() while model.active_path()
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit context restore failed: #{e.class}: #{e.message}"
          end
        end

        def prepare_active_path_for_finish(model)
          begin
            active_path = model.active_path()
            return if active_path.nil?

            primal_group = @indoor_model.primal_group
            if active_path_matches?(model, [primal_group])
              return
            end

            if primal_group && active_path.first == primal_group
              set_active_path(model, [primal_group])
              return
            end

            close_active_path(model)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit context finish preparation failed: #{e.class}: #{e.message}"
          end
        end

        def close_active_path(model)
          model.close_active() while model.active_path()
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit context close failed: #{e.class}: #{e.message}"
        end

        def mark_editable_primal_entities
          @editable_entity_ids = {}
          mark_editable(@indoor_model.primal_group)
        end

        def mark_editable(entity)
          begin
            return unless entity&.valid?()

            @editable_entity_ids[entity.entityID] = true
          rescue StandardError
            true
          end
        end

      end

    end
  end
end
