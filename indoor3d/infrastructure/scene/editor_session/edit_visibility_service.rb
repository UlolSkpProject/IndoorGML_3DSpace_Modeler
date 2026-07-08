# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        class EditVisibilityService
          def initialize(indoor_model:, visibility_controller:, validation_focus_controller:, geometry_visible:, with_unlocked:, invalidate_view:, invalidate_overlay:)
            @indoor_model = indoor_model
            @visibility_controller = visibility_controller
            @validation_focus_controller = validation_focus_controller
            @geometry_visible = geometry_visible
            @with_unlocked = with_unlocked
            @invalidate_view = invalidate_view
            @invalidate_overlay = invalidate_overlay
          end

          def apply_geometry_visibility
            return false unless primal_group_visibility_target?

            with_visibility_update_operation do
              set_primal_group_visible(@geometry_visible.call)
            end
            invalidate_view(Sketchup.active_model)
            true
          rescue StandardError => e
            log("Geometry visibility update failed: #{e.class}: #{e.message}")
            false
          end

          def apply_validation_focus_visibility
            return false unless validation_focus_active?

            runtime_count = 0
            visible_count = 0
            hidden_count = 0
            skipped_count = 0
            with_visibility_update_operation do
              set_primal_group_visible(true)
              Array(@indoor_model.cell_spaces).each do |cell_space|
                runtime_count += 1
                unless cell_space&.valid?
                  skipped_count += 1
                  next
                end

                group = cell_space.sketchup_group
                unless @visibility_controller.cell_space_visibility_target?(group)
                  skipped_count += 1
                  next
                end

                persistent_id = group.persistent_id
                unless @validation_focus_controller.visibility_snapshot?(persistent_id)
                  @validation_focus_controller.remember_visibility_snapshot(
                    persistent_id,
                    @visibility_controller.capture_cell_space_visibility(group)
                  )
                end
                visible = edit_mode_visible_cell_space?(cell_space)
                visible ? visible_count += 1 : hidden_count += 1
                with_unlocked(group) do
                  @visibility_controller.set_cell_space_render_visible(
                    group,
                    visible
                  )
                end
              end
            end
            log(
              "Validation focus visibility: runtime=#{runtime_count} " \
              "focus=#{@validation_focus_controller.focus_id_count} " \
              "visible=#{visible_count} hidden=#{hidden_count} skipped=#{skipped_count}"
            )
            invalidate_view(Sketchup.active_model)
            true
          rescue StandardError => e
            log("Validation focus visibility failed: #{e.class}: #{e.message}")
            false
          end

          def validation_visible_cell_space?(cell_space)
            return true unless validation_focus_active?
            return false unless cell_space&.valid?

            @validation_focus_controller.visible_cell_space?(cell_space)
          rescue StandardError
            false
          end

          def restore_validation_focus_visibility
            snapshots = @validation_focus_controller.visibility_snapshots
            return true if snapshots.empty?

            with_visibility_update_operation do
              each_valid_cell_space_group do |_cell_space, group|
                next unless snapshots.key?(group.persistent_id)

                with_unlocked(group) do
                  @visibility_controller.restore_cell_space_visibility(group, snapshots[group.persistent_id])
                end
              end
            end
            @validation_focus_controller.clear_visibility_snapshots
            apply_edit_mode_visibility_filter(ignore_validation: true) if @visibility_controller.filter_active?
            invalidate_view(Sketchup.active_model)
            true
          rescue StandardError => e
            log("Validation focus visibility restore failed: #{e.class}: #{e.message}")
            false
          end

          def apply_edit_mode_visibility_filter(ignore_validation: false)
            unless @visibility_controller.filter_active? || (!ignore_validation && validation_focus_active?)
              return apply_all_edit_mode_cell_space_visibility
            end

            with_visibility_update_operation do
              each_valid_cell_space_group do |cell_space, group|
                remember_edit_mode_visibility(group) if @visibility_controller.filter_active?
                with_unlocked(group) do
                  @visibility_controller.set_cell_space_render_visible(
                    group,
                    edit_mode_visible_cell_space?(cell_space, include_validation: !ignore_validation)
                  )
                end
              end
            end
            invalidate_view(Sketchup.active_model)
            true
          rescue StandardError => e
            log("Edit visibility filter apply failed: #{e.class}: #{e.message}")
            false
          end

          def apply_all_edit_mode_cell_space_visibility(restore_snapshots: true)
            with_visibility_update_operation do
              each_valid_cell_space_group do |_cell_space, group|
                snapshot = @visibility_controller.edit_mode_visibility_snapshot(group)
                with_unlocked(group) do
                  if restore_snapshots && snapshot
                    @visibility_controller.restore_cell_space_visibility(group, snapshot)
                  else
                    @visibility_controller.set_cell_space_render_visible(group, true)
                  end
                end
              end
            end
            @visibility_controller.clear_edit_mode_snapshots
            invalidate_view(Sketchup.active_model)
            true
          rescue StandardError => e
            log("Edit visibility filter clear failed: #{e.class}: #{e.message}")
            false
          end

          def restore_edit_mode_visibility
            return true if @visibility_controller.edit_mode_visibility_snapshots_empty?

            with_visibility_update_operation do
              each_valid_cell_space_group do |_cell_space, group|
                next unless @visibility_controller.edit_mode_visibility_snapshot?(group)

                snapshot = @visibility_controller.edit_mode_visibility_snapshot(group)
                with_unlocked(group) { @visibility_controller.restore_cell_space_visibility(group, snapshot) }
              end
            end
            @visibility_controller.clear_edit_mode_snapshots
            invalidate_view(Sketchup.active_model)
            true
          rescue StandardError => e
            log("Edit visibility filter restore failed: #{e.class}: #{e.message}")
            false
          end

          def normalize_visibility_for_non_edit_mode
            apply_all_edit_mode_cell_space_visibility(restore_snapshots: false)
            apply_geometry_visibility
            @invalidate_overlay.call
            true
          rescue StandardError => e
            log("Edit visibility normalize failed: #{e.class}: #{e.message}")
            false
          end

          def edit_mode_visible_cell_space?(cell_space, include_validation: true)
            if include_validation && validation_focus_active?
              return validation_visible_cell_space?(cell_space)
            end

            return false unless storey_filter_visible?(cell_space)
            return false unless cell_type_filter_visible?(cell_space)

            true
          end

          private

          def each_valid_cell_space_group
            @indoor_model.cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              group = cell_space.sketchup_group
              next unless @visibility_controller.cell_space_visibility_target?(group)

              yield cell_space, group
            end
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

          def with_unlocked(group)
            @with_unlocked.call(group) { yield }
          end

          def primal_group_visibility_target?
            primal_group = @indoor_model.primal_group
            primal_group&.valid? && primal_group.respond_to?(:visible=)
          rescue StandardError
            false
          end

          def set_primal_group_visible(visible)
            primal_group = @indoor_model.primal_group
            return false unless primal_group_visibility_target?

            with_unlocked(primal_group) do
              primal_group.visible = visible == true
            end
            true
          end

          def invalidate_view(model)
            @invalidate_view.call(model)
          end

          def remember_edit_mode_visibility(group)
            persistent_id = group.persistent_id
            snapshot = if @validation_focus_controller.visibility_snapshot?(persistent_id)
                         @validation_focus_controller.visibility_snapshot(persistent_id)
                       end
            @visibility_controller.remember_edit_mode_visibility(group, snapshot: snapshot)
          rescue StandardError
            false
          end

          def validation_focus_active?
            @validation_focus_controller.active?
          end

          def storey_filter_visible?(cell_space)
            return true if @visibility_controller.visible_storeys.empty?

            cell_storeys = StoreyFilter.labels_for(cell_space&.storey)
            cell_storeys.any? { |storey| @visibility_controller.visible_storeys.include?(storey) }
          end

          def cell_type_filter_visible?(cell_space)
            return true if @visibility_controller.visible_cell_types.empty?

            @visibility_controller.visible_cell_types.include?(cell_space&.cell_type)
          end

          def log(message)
            IndoorCore::Logger.puts("[IndoorGML] #{message}") if defined?(IndoorCore::Logger)
          end
        end
      end
    end
  end
end
