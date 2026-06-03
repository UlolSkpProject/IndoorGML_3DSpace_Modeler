# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditorSession
        def initialize(indoor_model)
          @indoor_model = indoor_model
          @editing = false
          @editable_entity_ids = {}
          @overlay = nil
          @overlay_registered = false
          @overlay_model = nil
          @dialog = EditModeDialog.new(@indoor_model)
          @previous_active_path = nil
          @editing_active_path_target = nil
          @enforcing_active_path = false
          @active_path_enforcement_suspended = false
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
          model = Sketchup.active_model()
          ensure_overlay_registered(model) if @dual_overlay_visible
          set_overlay_enabled(@editing || @dual_overlay_visible)
          invalidate_view(model)
          @dual_overlay_visible
        end

        def begin_editing
          return false if @editing

          @indoor_model.refresh_runtime_data()
          model = Sketchup.active_model()
          primal_group = @indoor_model.primal_group
          return false unless primal_group&.valid?()

          ensure_overlay_registered(model)
          @previous_active_path = active_path_snapshot(model)
          @editing = true
          @indoor_model.attach_edit_selection_observer(model)
          mark_editable_primal_entities()
          apply_lock_policy()
          unless activate_edit_context(model, [primal_group])
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

        def finish
          return false unless @editing

          model = Sketchup.active_model()
          @editing = false
          @editable_entity_ids = {}
          @editing_active_path_target = nil
          @indoor_model.detach_edit_selection_observer(model)
          restore_active_path(model)
          @previous_active_path = nil
          set_overlay_enabled(@dual_overlay_visible == true)
          @dialog.close()
          apply_lock_policy()
          invalidate_view(model)
          true
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
            invalidate_view(model)
            true
          rescue StandardError => e
            puts "[IndoorGML] CellSpace geometry edit activation failed: #{e.class}: #{e.message}"
            false
          end
        end

        def lock_entity(entity)
          begin
            return true unless lockable?(entity)
            return true if editable_entity?(entity)

            entity.locked = true
            true
          rescue StandardError
            true
          end
        end

        def unlock_entity(entity)
          begin
            return true unless lockable?(entity)

            entity.locked = false
            true
          rescue StandardError
            true
          end
        end

        def with_unlocked(entity)
          begin
            entities = temporary_unlock_entities(entity)
            entities.each { |target| unlock_entity(target) }
            yield
          ensure
            entities&.reverse_each { |target| lock_entity(target) }
          end
        end

        def apply_lock_policy
          if @editing
            mark_editable_primal_entities()
          else
            @editable_entity_ids = {}
            clear_feature_editable_flags()
          end

          indoor_entities.each do |entity|
            if editable_entity?(entity)
              unlock_entity(entity)
            else
              lock_entity(entity)
            end
          end
        end

        def active_path_changed(model)
          begin
            return unless @editing
            return if @enforcing_active_path
            return if @active_path_enforcement_suspended

            enforce_edit_context(model || Sketchup.active_model())
          rescue StandardError => e
            puts "[IndoorGML] Edit active path enforcement failed: #{e.class}: #{e.message}"
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

          @dialog.update_selection(@indoor_model.selected_cell_space_snapshot)
        end

        def cleanup_before_quit
          begin
            @dialog.close()
            finish() if @editing
          rescue StandardError => e
            puts "[IndoorGML] Edit shutdown cleanup failed: #{e.class}: #{e.message}"
          end
        end

        private

        def ensure_overlay_registered(model)
          begin
            if @overlay_registered && @overlay_model == model
              set_overlay_enabled(true)
              return
            end
            return unless model.respond_to?(:overlays)

            @overlay ||= EditModeOverlay.new(@indoor_model)
            remove_stale_overlay_instances(model)
            model.overlays().add(@overlay)
            @overlay_registered = true
            @overlay_model = model
            set_overlay_enabled(true)
          rescue StandardError => e
            puts "[IndoorGML] Edit mode overlay registration failed: #{e.class}: #{e.message}"
          end
        end

        def remove_stale_overlay_instances(model)
          stale_overlays = []
          model.overlays().each do |overlay|
            next unless overlay.overlay_id == EditModeOverlay::OVERLAY_ID
            next if overlay.equal?(@overlay)

            stale_overlays << overlay
          end
          stale_overlays.each { |overlay| model.overlays().remove(overlay) }
        end

        def set_overlay_enabled(enabled)
          begin
            return unless @overlay&.valid?()

            @overlay.enabled = enabled
          rescue StandardError => e
            puts "[IndoorGML] Edit mode overlay enable failed: #{e.class}: #{e.message}"
          end
        end

        def invalidate_view(model)
          model.active_view().invalidate() if model&.active_view()
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
            puts "[IndoorGML] Edit context activation failed: #{e.class}: #{e.message}"
            false
          end
        end

        def enforce_edit_context(model)
          target_path = valid_editing_active_path_target()
          return if target_path.empty?
          return if active_path_matches?(model, target_path)

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
            puts "[IndoorGML] Edit context restore failed: #{e.class}: #{e.message}"
          end
        end

        def mark_editable_primal_entities
          @editable_entity_ids = {}
          mark_editable(@indoor_model.primal_group)
          @indoor_model.cell_spaces.each do |cell_space|
            cell_space.editable = true if cell_space.respond_to?(:editable=)
            mark_editable(cell_space.sketchup_group)
          end
          @indoor_model.states.each { |state| state.editable = false if state.respond_to?(:editable=) }
          @indoor_model.transitions.each { |transition| transition.editable = false if transition.respond_to?(:editable=) }
        end

        def clear_feature_editable_flags
          @indoor_model.cell_spaces.each { |cell_space| cell_space.editable = false if cell_space.respond_to?(:editable=) }
          @indoor_model.states.each { |state| state.editable = false if state.respond_to?(:editable=) }
          @indoor_model.transitions.each { |transition| transition.editable = false if transition.respond_to?(:editable=) }
        end

        def mark_editable(entity)
          begin
            return unless entity&.valid?()

            @editable_entity_ids[entity.entityID] = true
          rescue StandardError
            true
          end
        end

        def indoor_entities
          entities = []
          entities << @indoor_model.primal_group
          @indoor_model.cell_spaces.each { |cell_space| entities << cell_space.sketchup_group }
          entities.compact.select { |entity| entity&.valid?() }
        end

        def temporary_unlock_entities(entity)
          [entity].compact.select { |target| target&.valid?() }
        end

        def lockable?(entity)
          begin
            entity&.valid?() && entity.respond_to?(:locked=)
          rescue StandardError
            false
          end
        end
      end

    end
  end
end
