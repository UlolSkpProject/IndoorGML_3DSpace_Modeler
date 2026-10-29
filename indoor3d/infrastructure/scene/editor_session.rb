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
        require_relative 'editor_session/validation_camera_controller'
        require_relative '../../utils/transformation'
        require_relative 'editor_session/edit_active_path_controller'
        require_relative 'editor_session/edit_visibility_service'
        include BatchProgress

        GRAPH_VISIBLE_ATTRIBUTE = 'graph_visible'
        GEOMETRY_VISIBLE_ATTRIBUTE = 'geometry_visible'
        VALIDATION_FOCUS_VISIBILITY_REAPPLY_DELAYS = [0, 0.05, 0.15, 0.35].freeze

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @editing = false
          @dialog = EditModeDialog.new(@indoor_model)
          @progress = nil
          @dual_overlay_visible = model_boolean_attribute(GRAPH_VISIBLE_ATTRIBUTE, true)
          @geometry_visible = model_boolean_attribute(GEOMETRY_VISIBLE_ATTRIBUTE, true)
          @validation_focus_controller = ValidationFocusController.new
          @validation_focus_zoom_generation = 0
          @validation_focus_camera_session_id = 0
          @validation_camera_controller = ValidationCameraController.new
          @lock_controller = LockController.new(indoor_model: @indoor_model)
          @visibility_controller = VisibilityController.new
          @overlay_controller = OverlayController.new(indoor_model: @indoor_model)
          @edit_visibility_service = build_edit_visibility_service
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
          apply_current_geometry_visibility()
          @geometry_visible
        end

        def apply_display_state
          set_dual_overlay_visible(dual_overlay_visible?)
          apply_current_geometry_visibility()
        end

        def apply_current_geometry_visibility
          if validation_focus_active?
            apply_validation_focus_visibility()
          elsif @editing
            apply_geometry_visibility()
            apply_edit_mode_visibility_filter()
          else
            normalize_visibility_for_non_edit_mode()
          end
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
          capture_and_apply_edit_mode_rendering_options
          @editing = true
          update_overlay_enabled()
          @indoor_model.attach_edit_selection_observer(model)
          activated = false
          @indoor_model.with_space_feature_constraint do
            apply_lock_policy()
            activated = activate_edit_context(model, [primal_group])
          end
          unless activated
            @editing = false
            @indoor_model.clear_dual_graph_selection_cache
            active_path_controller.reset_target
            @indoor_model.detach_edit_selection_observer(model)
            restore_validation_focus_rendering_options
            apply_lock_policy()
            return false
          end
          apply_all_edit_mode_cell_space_visibility
          apply_geometry_visibility unless validation_focus_active?
          @dialog.show()
          selection_changed()
          invalidate_view(model)
          true
        end

        def begin_validation_focus_editing(cell_gml_ids, row_states: nil)
          ids = Array(cell_gml_ids).map(&:to_s).reject(&:empty?)
          return false if ids.empty?

          @validation_focus_camera_session_id = @validation_focus_camera_session_id.to_i + 1
          validation_focus_controller.begin(ids)
          validation_focus_controller.set_focus_rows(row_states) if row_states
          capture_and_apply_validation_focus_rendering_options(ids.length)
          started = @editing ? true : begin_editing
          unless started
            restore_validation_focus_rendering_options
            clear_validation_focus
            return false
          end

          unless apply_validation_focus_visibility
            if defined?(IndoorCore::Logger)
              IndoorCore::Logger.puts '[IndoorGML] Validation focus edit mode failed: visibility apply returned false'
            end
            restore_validation_focus_visibility
            restore_validation_focus_rendering_options
            clear_validation_focus
            return false
          end
          defer_validation_focus_visibility
          invalidate_overlay_transition_visibility
          selection_changed
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus edit mode failed: #{e.class}: #{e.message}"
          restore_validation_focus_rendering_options
          restore_validation_focus_visibility
          clear_validation_focus
          false
        end

        def finish
          return false unless @editing

          if @indoor_model.respond_to?(:validation_focus_topology_dirty?) &&
             @indoor_model.validation_focus_topology_dirty? &&
             !@indoor_model.synchronize_validation_focus_topology_if_dirty
            IndoorCore::Logger.puts '[IndoorGML] Edit mode finish stopped: validation focus topology sync failed'
            return false
          end

          model = Sketchup.active_model()
          with_active_path_enforcement_suspended do
            active_path_controller.prepare_for_finish(model)
            restore_validation_focus_visibility
            normalize_visibility_for_non_edit_mode
            @editing = false
            @indoor_model.clear_dual_graph_selection_cache
            active_path_controller.reset_target
            reset_edit_mode_visibility_filter
            restore_validation_focus_rendering_options
            clear_validation_focus(restore_camera: false)
            @indoor_model.detach_edit_selection_observer(model)
            active_path_controller.close(model)
            restore_validation_focus_camera
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
          return visibility_controller.visible_storeys if visibility_controller.storey_filter_active?

          StoreyFilter.options_for(@indoor_model.cell_spaces).map { |option| option[:value] }
        end

        def visible_cell_type_labels
          visible_cell_types.map { |cell_type| CellSpaceType.label(cell_type) }
        end

        def set_visibility_filter(storeys:, cell_types:)
          return true if validation_focus_active?

          changed = visibility_controller.set_filter(
            storeys: normalize_storey_filter(storeys),
            cell_types: normalize_cell_type_filter(cell_types)
          )
          return true unless changed

          invalidate_overlay_transition_visibility
          apply_edit_mode_visibility_filter
          selection_changed
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit visibility filter update failed: #{e.class}: #{e.message}"
          false
        end

        def refresh_visibility_filter
          invalidate_overlay_transition_visibility
          validation_focus_active? ? apply_validation_focus_visibility : apply_edit_mode_visibility_filter
        end

        def dual_overlay_state_visible?(state)
          return false unless state&.valid?

          cell_space = state.duality_cell
          return false unless cell_space&.valid?

          edit_visibility_service.edit_mode_visible_cell_space?(cell_space)
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

        def set_validation_focus_highlight(cell_gml_ids, code = nil, row_id: nil, row_cells: nil, states: nil, transitions: nil)
          cancel_validation_focus_zoom
          clearing_row_selection = Array(cell_gml_ids).empty? && row_id.to_s.empty?
          highlight_options = {}
          highlight_options[:row_id] = row_id unless row_id.nil?
          highlight_options[:row_cells] = row_cells unless row_cells.nil?
          highlight_options[:states] = states unless states.nil?
          highlight_options[:transitions] = transitions unless transitions.nil?
          if highlight_options.empty?
            validation_focus_controller.set_highlight(cell_gml_ids, code)
          else
            validation_focus_controller.set_highlight(cell_gml_ids, code, **highlight_options)
          end
          if clearing_row_selection
            context_restored = reset_validation_focus_row_edit_context
            restore_validation_focus_camera
            unless context_restored
              IndoorCore::Logger.puts '[IndoorGML] Validation focus highlight clear failed: primal edit context was not restored'
              return false
            end
          end
          unless apply_validation_focus_visibility
            if defined?(IndoorCore::Logger)
              IndoorCore::Logger.puts '[IndoorGML] Validation focus highlight failed: visibility apply returned false'
            end
            return false
          end
          update_validation_error_geometry(row_id)
          invalidate_overlay_transition_visibility
          invalidate_view(Sketchup.active_model())
          unless row_id.to_s.empty?
            camera_scheduled = zoom_validation_focus_highlight(row_id: row_id)
            IndoorCore::Logger.puts '[IndoorGML] Validation focus camera could not be scheduled' unless camera_scheduled
          end
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus highlight failed: #{e.class}: #{e.message}"
          false
        end

        def reset_validation_focus_row_edit_context
          model = Sketchup.active_model()
          model.selection.clear if model&.respond_to?(:selection) && model.selection

          primal_group = @indoor_model.primal_group
          return false unless model && primal_group&.valid?

          target_path = [primal_group]
          active_path_controller.set_target_path(target_path)
          active_path_controller.set(model, target_path)
          selection_changed()
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus row deselection failed: #{e.class}: #{e.message}"
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

        def validation_focus_row(row_id)
          validation_focus_controller.focus_row(row_id)
        rescue StandardError
          nil
        end

        def validation_focus_highlight_active?
          validation_focus_controller.highlight_active?
        end

        def validation_focus_highlight_row_id
          validation_focus_controller.highlight_row_id
        end

        def validation_focus_highlight_row_cells
          validation_focus_controller.highlighted_row_cells
        end

        def validation_focus_highlight_row_include_cell?(cell_space)
          validation_focus_controller.highlighted_row_include_cell?(cell_space&.id)
        end

        def validation_focus_snapshot
          validation_focus_controller.snapshot
        end

        def restore_validation_focus_snapshot(snapshot, refresh: true)
          validation_focus_controller.restore!(snapshot)
          if refresh
            refresh_validation_focus_after_mutation
          else
            update_validation_error_geometry(validation_focus_controller.highlight_row_id)
          end
        end

        def add_validation_focus_highlight_cell(cell_space, refresh: true)
          payload = validation_focus_controller.add_highlight_cell(cell_space&.id)
          return nil unless payload

          refresh_validation_focus_after_mutation if refresh
          payload
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus highlight add failed: #{e.class}: #{e.message}"
          nil
        end

        def remove_validation_focus_highlight_cell(cell_space, refresh: true)
          payloads = validation_focus_controller.remove_cell(cell_space&.id)
          return [] if payloads.empty?

          refresh_validation_focus_after_mutation if refresh
          payloads
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus highlight remove failed: #{e.class}: #{e.message}"
          []
        end

        def reconcile_validation_focus_cells(cell_spaces)
          payloads = validation_focus_controller.reconcile_cells(Array(cell_spaces).map(&:id))
          refresh_validation_focus_after_mutation unless payloads.empty?
          payloads
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus cell reconciliation failed: #{e.class}: #{e.message}"
          []
        end

        def refresh_validation_focus_after_mutation
          apply_validation_focus_visibility
          overlay_controller.invalidate_validation_geometry_cache
          update_validation_error_geometry(validation_focus_controller.highlight_row_id)
          invalidate_overlay_transition_visibility
          invalidate_view(Sketchup.active_model())
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus mutation refresh failed: #{e.class}: #{e.message}"
          false
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
          edit_visibility_service.apply_geometry_visibility
        end

        def apply_validation_focus_visibility
          edit_visibility_service.apply_validation_focus_visibility
        end

        def validation_visible_cell_space?(cell_space)
          edit_visibility_service.validation_visible_cell_space?(cell_space)
        end

        def restore_validation_focus_visibility
          edit_visibility_service.restore_validation_focus_visibility
        end

        def clear_validation_focus(restore_camera: true)
          cancel_validation_focus_zoom
          @validation_focus_camera_session_id = @validation_focus_camera_session_id.to_i + 1
          restore_validation_focus_camera if restore_camera
          validation_focus_controller.clear
          overlay_controller.clear_validation_geometry
          overlay_controller.invalidate_validation_geometry_cache
          invalidate_overlay_transition_visibility
        end

        def update_validation_error_geometry(row_id)
          row = validation_focus_controller.focus_row(row_id)
          return overlay_controller.clear_validation_geometry unless row

          overlay_controller.set_validation_geometry(row)
        rescue StandardError => e
          IndoorCore::Logger.puts(
            "[IndoorGML] Validation error geometry update failed: " \
            "#{e.class}: #{e.message}"
          )
          overlay_controller.clear_validation_geometry
        end

        def apply_edit_mode_visibility_filter(ignore_validation: false)
          edit_visibility_service.apply_edit_mode_visibility_filter(ignore_validation: ignore_validation)
        end

        def apply_all_edit_mode_cell_space_visibility
          edit_visibility_service.apply_all_edit_mode_cell_space_visibility
        end

        def normalize_visibility_for_non_edit_mode
          edit_visibility_service.normalize_visibility_for_non_edit_mode
        end

        def capture_and_apply_validation_focus_rendering_options(focus_cell_count)
          validation_focus_controller.capture_and_apply_rendering_options(Sketchup.active_model, focus_cell_count)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus rendering option update failed: #{e.class}: #{e.message}"
        end

        def capture_and_apply_edit_mode_rendering_options
          validation_focus_controller.capture_and_apply_hidden_rendering_options(Sketchup.active_model)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit mode rendering option update failed: #{e.class}: #{e.message}"
        end

        def restore_validation_focus_rendering_options
          validation_focus_controller.restore_rendering_options(Sketchup.active_model)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus rendering option restore failed: #{e.class}: #{e.message}"
        end

        def active_path_changed(model)
          return reconcile_after_transaction(model, source: :transaction_replay) if @indoor_model.transaction_replay_pending?

          active_path_controller.active_path_changed(
            model,
            editing: @editing,
            reenter: -> { reenter_editing_from_primal_path }
          )
          defer_validation_focus_visibility if validation_focus_active?
        end

        def reconcile_after_transaction(model, source: nil)
          if @indoor_model.transaction_replay_pending?
            active_path_controller.reconcile_transaction_replay_path(model, editing: @editing)
          else
            active_path_controller.reconcile_after_runtime_restore(model, editing: @editing)
          end
          clear_overlay_transition_cache
          selection_changed if @editing
          invalidate_view(model)
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Edit session #{source || 'transaction'} reconciliation failed: #{e.class}: #{e.message}"
          false
        end

        def with_active_path_enforcement_suspended
          active_path_controller.with_suspended_enforcement { yield }
        end

        def selection_changed
          @indoor_model.refresh_dual_graph_selection_cache
          return unless @editing

          overlay_controller.invalidate_transition_selection
          @dialog.update_selection(@indoor_model.selected_edit_mode_snapshot)
          # Selection-only highlight passes must redraw without rebuilding
          # State positions, Transition routes or Native Ref-Graphs.
          invalidate_view(@indoor_model.model) if dual_overlay_visible?
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
            restoring_edit_visibility = @editing || validation_focus_active?
            @dialog.close_without_finish()
            restore_validation_focus_visibility
            normalize_visibility_for_non_edit_mode if restoring_edit_visibility
            @editing = false
            @indoor_model.clear_dual_graph_selection_cache
            active_path_controller.reset
            restore_validation_focus_rendering_options
            reset_edit_mode_visibility_filter
            clear_validation_focus
            @progress = nil
            set_overlay_enabled(false)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit model close cleanup failed: #{e.class}: #{e.message}"
          end
        end

        def invalidate_overlay_transition_points
          # Topology refresh can replace a CellSpace Group without triggering
          # a SelectionObserver event. Reconcile its cached ownership here,
          # not on camera redraw.
          @indoor_model.refresh_dual_graph_selection_cache if @editing
          overlay_controller.invalidate_transition_points
        end

        def invalidate_overlay_primal_render_transform
          overlay_controller.invalidate_primal_render_transform
        end

        def invalidate_overlay_transitions(transitions)
          overlay_controller.invalidate_transitions(transitions)
        end

        def remove_overlay_transitions(transitions)
          overlay_controller.remove_transitions(transitions)
        end

        def invalidate_overlay_transition_visibility
          overlay_controller.invalidate_transition_visibility
        end

        def clear_overlay_transition_cache
          overlay_controller.clear_transition_cache
        end

        def finish_overlay_transition_transform_preview(model = Sketchup.active_model, source: :commit)
          changed = overlay_controller.finish_transition_transform_preview(source: source)
          invalidate_view(model) if changed
          changed
        end

        def begin_overlay_transition_topology_sync(cell_ids)
          overlay_controller.begin_transition_topology_sync(cell_ids)
        end

        def complete_overlay_transition_topology_sync(cell_ids, model = Sketchup.active_model)
          changed = overlay_controller.complete_transition_topology_sync(cell_ids)
          invalidate_view(model) if changed
          changed
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

        def validation_camera_controller
          @validation_camera_controller ||= ValidationCameraController.new
        end

        # Report dialog close must invalidate any pending Row camera work
        # without touching Validation, Visibility, Overlay or Edit state.
        def suspend_validation_focus_camera
          cancel_validation_focus_zoom
          restore_validation_focus_camera
        end

        def restore_validation_focus_camera
          result = validation_camera_controller.restore
          unless result[:ok]
            IndoorCore::Logger.puts "[IndoorGML] Validation focus Camera restore failed: #{result[:message]}"
          end
          result
        end

        def zoom_validation_focus_highlight(row_id:)
          expected_row_id = row_id.to_s
          return false if expected_row_id.empty?
          return false unless defined?(UI) && UI.respond_to?(:start_timer)

          model = @indoor_model.model
          return false unless model && Sketchup.active_model.equal?(model)
          result = validation_camera_controller.capture(model)
          unless result[:ok]
            IndoorCore::Logger.puts "[IndoorGML] Validation focus Camera capture failed: #{result[:message]}"
            return false
          end

          generation = @validation_focus_zoom_generation.to_i
          session_id = @validation_focus_camera_session_id
          schedule_validation_focus_camera_step(generation, expected_row_id, 'camera sequence',
                                                model: model, session_id: session_id) do
            groups = validation_focus_highlight_groups
            next if groups.empty?

            bounds = validation_focus_bounds(groups)
            next unless bounds

            camera_result = validation_camera_controller.apply(
              model,
              orientation: :iso,
              projection: :parallel,
              zoom: :bounds,
              target: bounds,
              margin: ValidationCameraController::DEFAULT_MARGIN
            )
            unless camera_result[:ok]
              IndoorCore::Logger.puts "[IndoorGML] Validation focus Camera failed: #{camera_result[:message]}"
            end
          end
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus camera scheduling failed: #{e.class}: #{e.message}"
          false
        end

        # Definition bounds are local to the CellSpace instance. Transform each corner
        # exactly once with the project's ActivePath-aware World transformation.
        # Entity#bounds is parent-context AABB and must not be transformed again.
        def validation_focus_bounds(groups)
          bounds = Geom::BoundingBox.new
          Array(groups).each do |group|
            next unless group&.valid?

            local_bounds = group.definition.bounds
            next unless local_bounds&.valid?

            world_transform = Utils::Transformation.entity_world_transformation(group)
            8.times do |index|
              bounds.add(local_bounds.corner(index).transform(world_transform))
            end
          end
          bounds.valid? ? bounds : nil
        end

        def schedule_validation_focus_camera_step(generation, expected_row_id, label, model:, session_id:, &step)
          UI.start_timer(0, false) do
            begin
              next unless generation == @validation_focus_zoom_generation
              next unless session_id == @validation_focus_camera_session_id
              next unless model.equal?(@indoor_model.model) && model.equal?(Sketchup.active_model)
              next if model.respond_to?(:valid?) && !model.valid?
              next unless validation_camera_controller.captured_model?(model)
              next unless validation_focus_active?
              next unless validation_focus_controller.highlight_row_id.to_s == expected_row_id

              step.call
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Validation focus highlight #{label} failed: #{e.class}: #{e.message}"
              restore_validation_focus_camera
            end
          end
        end

        def validation_focus_highlight_groups
          validation_focus_highlight_cell_spaces.filter_map do |cell_space|
            group = cell_space&.valid_sketchup_group
            group if group&.valid?
          rescue StandardError
            nil
          end
        end

        def cancel_validation_focus_zoom
          @validation_focus_zoom_generation = @validation_focus_zoom_generation.to_i + 1
        end

        def edit_visibility_service
          @edit_visibility_service ||= build_edit_visibility_service
        end

        def active_path_controller
          @active_path_controller ||= EditActivePathController.new(
            indoor_model: @indoor_model,
            on_lock: -> { apply_lock_policy },
            on_selection: -> { selection_changed },
            on_invalidate: ->(model) { invalidate_view(model) }
          )
        end

        def reset_edit_mode_visibility_filter
          visibility_controller.reset_filter
        end

        def defer_validation_focus_visibility
          return false unless defined?(UI) && UI.respond_to?(:start_timer)

          scheduled = false
          VALIDATION_FOCUS_VISIBILITY_REAPPLY_DELAYS.each do |delay|
            UI.start_timer(delay, false) do
              begin
                if validation_focus_active?
                  apply_validation_focus_visibility
                  invalidate_overlay_transition_visibility
                  selection_changed
                  invalidate_view(Sketchup.active_model())
                end
              rescue StandardError => e
                IndoorCore::Logger.puts "[IndoorGML] Deferred validation focus visibility failed: #{e.class}: #{e.message}"
              end
            end
            scheduled = true
          end
          scheduled
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Deferred validation focus visibility scheduling failed: #{e.class}: #{e.message}"
          false
        end

        def normalize_storey_filter(values)
          StoreyFilter.normalize_labels(values)
        end

        def normalize_cell_type_filter(values)
          Array(values).map do |value|
            label = value.to_s.strip
            next nil if label.empty?

            CellSpaceType::LABELS.value?(label) ? CellSpaceType.from_label(label) : nil
          end.compact.uniq
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
            dual_overlay_visible: @dual_overlay_visible
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

        def build_edit_visibility_service
          EditVisibilityService.new(
            indoor_model: @indoor_model,
            visibility_controller: visibility_controller,
            validation_focus_controller: validation_focus_controller,
            geometry_visible: -> { geometry_visible? },
            with_unlocked: ->(entity, &block) { with_unlocked(entity, &block) },
            invalidate_view: ->(model) { invalidate_view(model) },
            invalidate_overlay: -> { invalidate_overlay_transition_visibility }
          )
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
