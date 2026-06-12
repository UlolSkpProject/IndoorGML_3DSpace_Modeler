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
          @progress = nil
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
          update_overlay_enabled()
          invalidate_view(model)
          @dual_overlay_visible
        end

        def progress_active?
          @progress && @progress[:active] == true
        end

        def progress_current
          @progress ? @progress[:current].to_i : 0
        end

        def progress_total
          @progress ? @progress[:total].to_i : 0
        end

        def progress_message
          @progress ? @progress[:message].to_s : ''
        end

        def start_progress(total, message)
          @progress = {
            active: true,
            current: 0,
            total: [total.to_i, 0].max,
            message: message.to_s
          }
          model = Sketchup.active_model()
          ensure_overlay_registered(model)
          update_overlay_enabled()
          invalidate_view(model)
          true
        end

        def update_progress(current, message = nil)
          return false unless @progress

          @progress[:current] = [current.to_i, 0].max
          @progress[:message] = message.to_s if message
          invalidate_view(Sketchup.active_model())
          true
        end

        def finish_progress
          @progress = nil
          model = Sketchup.active_model()
          update_overlay_enabled()
          invalidate_view(model)
          true
        end

        def run_batched(items, message:, batch_size: 20, complete: nil, failure: nil, &block)
          items = Array(items)
          return false if items.empty?

          batch_size = [batch_size.to_i, 1].max
          index = 0
          total = items.length
          start_progress(total, message)

          processor = nil
          processor = proc do
            begin
              limit = [index + batch_size, total].min
              while index < limit
                block.call(items[index], index) if block
                index += 1
              end
              update_progress(index, message)
              if index < total
                UI.start_timer(0, false) { processor.call }
              else
                finish_progress()
                complete&.call()
              end
            rescue StandardError => e
              finish_progress()
              if failure
                failure.call(e)
              else
                IndoorCore::Logger.puts "[IndoorGML] Batched operation failed: #{e.class}: #{e.message}"
              end
            end
          end
          UI.start_timer(0, false) { processor.call }
          true
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
          with_active_path_enforcement_suspended do
            prepare_active_path_for_finish(model)
            @editing = false
            @editable_entity_ids = {}
            @editing_active_path_target = nil
            @indoor_model.detach_edit_selection_observer(model)
            close_active_path(model)
            @previous_active_path = nil
            update_overlay_enabled()
            @dialog.close()
            apply_lock_policy()
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

        def lock_entity(entity)
          begin
            return true unless lockable?(entity)
            return true if editable_entity?(entity)
            return true if entity.respond_to?(:locked?) && entity.locked?

            entity.locked = true
            true
          rescue StandardError
            true
          end
        end

        def unlock_entity(entity)
          begin
            return true unless lockable?(entity)
            return true if entity.respond_to?(:locked?) && !entity.locked?

            entity.locked = false
            true
          rescue StandardError
            true
          end
        end

        def with_unlocked(entity)
          begin
            entities = temporary_unlock_entities(entity)
            lock_states = entities.to_h do |target|
              [target, target.respond_to?(:locked?) && target.locked?]
            end
            entities.each { |target| unlock_entity(target) if lock_states[target] }
            yield
          ensure
            entities&.reverse_each { |target| lock_entity(target) if lock_states&.[](target) }
          end
        end

        def apply_lock_policy
          @editable_entity_ids = {}
          primal_group = @indoor_model.primal_group
          return unless primal_group&.valid?

          @editing ? unlock_entity(primal_group) : lock_entity(primal_group)
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

        def recover_unlocked_primal_after_transaction(model)
          begin
            return false if @editing

            primal_group = @indoor_model.primal_group
            return false unless primal_group&.valid?
            return false unless primal_group.respond_to?(:locked?)
            return false if primal_group.locked?

            reenter_editing_from_primal_path(model || Sketchup.active_model)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Unlocked primal recovery failed: #{e.class}: #{e.message}"
            false
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
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay registration failed: #{e.class}: #{e.message}"
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
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay enable failed: #{e.class}: #{e.message}"
          end
        end

        def update_overlay_enabled
          set_overlay_enabled(@editing || @dual_overlay_visible == true || progress_active?)
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
