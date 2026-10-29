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
        require_relative 'editor_session/validation_focus_visibility_service'
        require_relative 'editor_session/validation_result_focus_service'
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
          @validation_focus_visibility_row_generation = 0
          @validation_camera_controller = ValidationCameraController.new
          @rendering_options_manager = RenderingOptionsPolicy::Manager.new
          @lock_controller = LockController.new(indoor_model: @indoor_model)
          @visibility_controller = VisibilityController.new
          @overlay_controller = OverlayController.new(indoor_model: @indoor_model)
          @edit_visibility_service = build_edit_visibility_service
          @active_path_controller = EditActivePathController.new(
            indoor_model: @indoor_model,
            on_lock: -> { apply_lock_policy },
            on_selection: -> { selection_changed },
            on_invalidate: ->(model) { invalidate_view(model) },
            on_rendering_context: ->(model, path) { apply_rendering_context(model, path) }
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
          unless capture_and_apply_edit_mode_rendering_options
            restore_validation_focus_rendering_options
            return false
          end
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
          apply_all_edit_mode_cell_space_visibility unless validation_focus_active?
          apply_geometry_visibility unless validation_focus_active?
          @dialog.show()
          selection_changed()
          invalidate_view(model)
          true
        end

        def begin_validation_focus_editing(cell_gml_ids, row_states: nil)
          ids = Array(cell_gml_ids).map(&:to_s).reject(&:empty?)
          return false if ids.empty? || validation_focus_active?

          was_editing = @editing
          @validation_focus_camera_session_id = @validation_focus_camera_session_id.to_i + 1
          # Preserve normal/edit-mode values before Validation applies its session policy.
          unless capture_and_apply_edit_mode_rendering_options
            restore_validation_focus_rendering_options unless was_editing
            return false
          end
          validation_focus_controller.begin(ids)
          validation_focus_controller.set_focus_rows(row_states) if row_states
          unless edit_visibility_service.begin_validation_visibility_session
            restore_rendering_after_failed_validation_entry(was_editing)
            clear_validation_focus
            return false
          end
          unless capture_and_apply_validation_focus_rendering_options(ids.length)
            restore_validation_focus_visibility
            restore_rendering_after_failed_validation_entry(was_editing)
            clear_validation_focus
            return false
          end
          started = @editing ? true : begin_editing
          unless started
            restore_validation_focus_visibility
            restore_rendering_after_failed_validation_entry(was_editing)
            clear_validation_focus
            return false
          end

          unless apply_validation_focus_visibility
            if defined?(IndoorCore::Logger)
              IndoorCore::Logger.puts '[IndoorGML] Validation focus edit mode failed: visibility apply returned false'
            end
            restore_validation_focus_visibility
            restore_rendering_after_failed_validation_entry(was_editing)
            clear_validation_focus
            return false
          end
          defer_validation_focus_visibility
          invalidate_overlay_transition_visibility
          selection_changed
          invalidate_view(Sketchup.active_model())
          focus_started = validation_result_focus_service.begin_session(@indoor_model.model)
          if focus_started[:ok]
            update_overlay_enabled
            return true
          end

          IndoorCore::Logger.puts "[IndoorGML] Validation Focus coordinator startup failed: #{focus_started[:errors].inspect}"
          restore_validation_focus_visibility
          restore_rendering_after_failed_validation_entry(was_editing)
          clear_validation_focus
          false
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation focus edit mode failed: #{e.class}: #{e.message}"
          restore_rendering_after_failed_validation_entry(was_editing)
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
          was_validation_focus = validation_focus_active?
          with_active_path_enforcement_suspended do
            active_path_controller.prepare_for_finish(model)
            if was_validation_focus
              cleanup = validation_result_focus_service.end_session(
                model: model,
                restore_visibility: -> { restore_validation_focus_visibility },
                restore_rendering: -> { restore_validation_focus_rendering_options },
                restore_camera: false # Stage 1 restores after ActivePath close.
              )
              return false unless cleanup[:ok]
            else
              normalize_visibility_for_non_edit_mode
              return false unless restore_validation_focus_rendering_options
            end
            @editing = false
            @indoor_model.clear_dual_graph_selection_cache
            active_path_controller.reset_target
            reset_edit_mode_visibility_filter
            clear_validation_focus(restore_camera: false)
            @indoor_model.detach_edit_selection_observer(model)
            active_path_controller.close(model)
            camera_restore = restore_validation_focus_camera
            active_path_controller.clear_previous_path
            update_overlay_enabled()
            @dialog.close()
            apply_lock_policy()
            apply_geometry_visibility() unless was_validation_focus
            invalidate_view(model)
            camera_restore[:ok] == true
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
          response = validation_result_focus_service.focus_row(
            cell_gml_ids, code, row_id: row_id, row_cells: row_cells,
            states: states, transitions: transitions
          )
          unless response[:ok]
            IndoorCore::Logger.puts "[IndoorGML] Validation Result Focus failed: #{response[:errors].inspect}"
          end
          response[:ok]
        end

        def last_validation_focus_result
          validation_result_focus_service.last_result
        end

        # Report Dialog close ends the Validation Scene session, not the
        # ordinary Edit Mode (which owns DualGraph, selection and lock policy).
        def close_validation_result_focus
          return true unless validation_focus_active?

          model = @indoor_model.model
          return false unless model && model.equal?(Sketchup.active_model)
          return false unless reset_validation_focus_row_edit_context

          cleanup = validation_result_focus_service.end_session(
            model: model,
            restore_visibility: -> { restore_validation_focus_visibility },
            restore_rendering: -> { restore_rendering_after_failed_validation_entry(true) },
            restore_camera: false
          )
          unless cleanup[:ok]
            IndoorCore::Logger.puts "[IndoorGML] Validation report Scene restore failed: #{cleanup[:errors].inspect}"
            return false
          end

          camera = restore_validation_focus_camera
          return false unless camera[:ok]

          clear_validation_focus(restore_camera: false)
          update_overlay_enabled
          return false unless apply_rendering_context(model, model.active_path)

          invalidate_view(model)
          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation report close restore failed: #{e.class}: #{e.message}"
          false
        end

        def restore_validation_focus_previous_edit_context(path)
          model = @indoor_model.model
          primal = @indoor_model.primal_group
          return false unless model && model.equal?(Sketchup.active_model)
          return false if path.empty? || path.first != primal
          return false unless path.all? { |entity| entity&.valid? }

          active_path_controller.set_target_path(path)
          active_path_controller.set(model, path)
          apply_rendering_context(model, model.active_path)
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Validation previous edit context restore failed: #{e.class}: #{e.message}"
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
          return false unless apply_rendering_context(model, model.active_path)

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
          return false unless apply_validation_focus_visibility

          apply_rendering_context(Sketchup.active_model, Sketchup.active_model&.active_path)
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
          @validation_focus_visibility_row_generation = @validation_focus_visibility_row_generation.to_i + 1
          restore_validation_focus_camera if restore_camera
          validation_focus_controller.clear
          @validation_result_focus_service&.discard
          overlay_cleared = overlay_controller.end_validation_session
          unless overlay_cleared
            IndoorCore::Logger.puts '[IndoorGML] Validation overlay session cleanup failed'
          end
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

        def rendering_options_manager
          @rendering_options_manager ||= RenderingOptionsPolicy::Manager.new
        end

        def apply_rendering_context(model, path)
          return true unless @editing || validation_focus_active?

          validation = validation_focus_active?
          primal = @indoor_model.primal_group
          active_path = Array(path)
          editing_cell = validation && active_path.length == 2 && active_path.first == primal &&
            Array(@indoor_model.cell_spaces).any? do |cell|
              cell&.valid? && cell.sketchup_group == active_path.last
            end
          context = RenderingOptionsPolicy.current_context(
            validation: validation,
            path: active_path,
            primal_group: primal,
            cell_space_editing: editing_cell,
            row_selected: !validation_focus_controller.highlight_row_id.to_s.empty?
          )

          values = RenderingOptionsPolicy.context_values(context)
          scope = validation ? :row : :edit
          unless validation && (context[:row_selected] || context[:group_editing])
            restored = rendering_options_manager.restore(model, scope: :row)
            return log_rendering_failure('row reset', restored) unless restored[:ok]
          end
          result = rendering_options_manager.apply(model, scope: scope, values: values)
          return log_rendering_failure('context', result) unless result[:ok]

          true
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Rendering Context failed: #{e.class}: #{e.message}"
          false
        end

        def capture_and_apply_validation_focus_rendering_options(_focus_cell_count)
          model = @indoor_model.model
          captured = rendering_options_manager.capture(model, scope: :session)
          return log_rendering_failure('session capture', captured) unless captured[:ok]

          applied = rendering_options_manager.apply(
            model, scope: :session, values: RenderingOptionsPolicy.validation_session
          )
          return log_rendering_failure('session apply', applied) unless applied[:ok]

          true
        end

        def capture_and_apply_edit_mode_rendering_options
          model = @indoor_model.model
          captured = rendering_options_manager.capture(model, scope: :edit)
          return log_rendering_failure('edit capture', captured) unless captured[:ok]

          applied = rendering_options_manager.apply(
            model, scope: :edit, values: RenderingOptionsPolicy.base_edit
          )
          return log_rendering_failure('edit apply', applied) unless applied[:ok]

          true
        end

        def restore_rendering_after_failed_validation_entry(was_editing)
          return restore_validation_focus_rendering_options unless was_editing

          model = @indoor_model.model
          %i[row session].each do |scope|
            restored = rendering_options_manager.restore(model, scope: scope)
            return log_rendering_failure("failed entry #{scope} restore", restored) unless restored[:ok]
          end
          true
        end

        def restore_validation_focus_rendering_options
          result = rendering_options_manager.restore_all(@indoor_model.model)
          return log_rendering_failure('restore', result) unless result[:ok]

          true
        end

        def log_rendering_failure(label, result)
          IndoorCore::Logger.puts "[IndoorGML] RenderingOptions #{label} failed: #{result[:errors].inspect}"
          false
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
          return false unless apply_rendering_context(model, model&.active_path)
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
            if validation_focus_active?
              cleanup = validation_result_focus_service.end_session(
                model: @indoor_model.model,
                restore_visibility: -> { restore_validation_focus_visibility },
                restore_rendering: -> { restore_validation_focus_rendering_options }
              )
              unless cleanup[:ok]
                IndoorCore::Logger.puts "[IndoorGML] Edit model close: Validation Scene restore incomplete: #{cleanup[:errors].inspect}"
                return false
              end
            elsif restoring_edit_visibility
              normalize_visibility_for_non_edit_mode
              return false unless restore_validation_focus_rendering_options
            end
            @editing = false
            @indoor_model.clear_dual_graph_selection_cache
            active_path_controller.reset
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

        def validation_result_focus_service
          @validation_result_focus_service ||= ValidationResultFocusService.new(
            indoor_model: @indoor_model,
            focus: validation_focus_controller,
            cancel_async: -> do
              cancel_validation_focus_zoom
              @validation_focus_visibility_row_generation = @validation_focus_visibility_row_generation.to_i + 1
            end,
            apply_visibility: -> { apply_validation_focus_visibility },
            apply_rendering: -> { apply_rendering_context(@indoor_model.model, @indoor_model.model&.active_path) },
            show_overlay: ->(row_id) { update_validation_error_geometry(row_id) },
            clear_overlay: -> { overlay_controller.clear_validation_geometry },
            schedule_camera: ->(row_id) { zoom_validation_focus_highlight(row_id: row_id) },
            restore_camera: -> { restore_validation_focus_camera },
            restore_context: -> { reset_validation_focus_row_edit_context },
            restore_previous_context: ->(path) { restore_validation_focus_previous_edit_context(path) },
            refresh: -> do
              invalidate_overlay_transition_visibility
              invalidate_view(@indoor_model.model)
            end
          )
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
            on_invalidate: ->(model) { invalidate_view(model) },
            on_rendering_context: ->(model, path) { apply_rendering_context(model, path) }
          )
        end

        def reset_edit_mode_visibility_filter
          visibility_controller.reset_filter
        end

        def defer_validation_focus_visibility
          return false unless defined?(UI) && UI.respond_to?(:start_timer)

          model = @indoor_model.model
          session_id = edit_visibility_service.validation_visibility_generation
          row_generation = @validation_focus_visibility_row_generation
          return false unless model && Sketchup.active_model.equal?(model)

          VALIDATION_FOCUS_VISIBILITY_REAPPLY_DELAYS.each do |delay|
            UI.start_timer(delay, false) do
              begin
                next unless validation_focus_active?
                next unless model.equal?(@indoor_model.model) && model.equal?(Sketchup.active_model)
                next if model.respond_to?(:valid?) && !model.valid?
                next unless session_id == edit_visibility_service.validation_visibility_generation
                next unless row_generation == @validation_focus_visibility_row_generation

                if apply_validation_focus_visibility
                  invalidate_overlay_transition_visibility
                  selection_changed
                  invalidate_view(model)
                end
              rescue StandardError => e
                IndoorCore::Logger.puts "[IndoorGML] Deferred validation focus visibility failed: #{e.class}: #{e.message}"
              end
            end
          end
          true
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
