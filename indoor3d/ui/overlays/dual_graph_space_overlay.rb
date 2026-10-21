# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DualGraphSpaceOverlay < SpaceOverlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.dual_graph_space_overlay'
        OVERLAY_NAME = 'IndoorGML Dual Graph Overlay'

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @transition_curve_builder = TransitionCurveBuilder.new(indoor_model: @indoor_model, transform_context: self)
          @transition_renderer = TransitionOverlayRenderer.new(curve_builder: @transition_curve_builder)
          @reference_point_debug_renderer = ReferencePointDebugOverlayRenderer.new(
            indoor_model: @indoor_model,
            transform_context: self
          )
          @reference_graph_debug_renderer = ReferenceGraphDebugOverlayRenderer.new(
            indoor_model: @indoor_model,
            transform_context: self
          )
          @state_renderer = StateOverlayRenderer.new(indoor_model: @indoor_model, transform_context: self)
          @transition_transform_snapshots = nil
          @transition_transforming_cell_ids = {}
          @transition_transform_pending_cell_ids = {}
          @primal_transform_preview_active = false
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows IndoorGML state and transition geometry.')
        end

        def invalidate_transition_points
          @transition_curve_builder.invalidate
          @state_renderer.clear_cache
        end

        # CellSpace transitions stay suppressed across commit until topology has
        # been synchronized. Primal transforms do not alter adjacency and can be
        # released immediately at transaction completion.
        def finish_transition_transform_preview(source: :commit)
          ensure_transition_transform_state
          current_snapshots = selected_transition_transform_snapshots
          changed = transition_transform_snapshots_changed?(@transition_transform_snapshots, current_snapshots)
          suppression_changed = false
          if source == :commit
            suppression_changed = @primal_transform_preview_active == true
            @primal_transform_preview_active = false
          else
            suppression_changed = transition_transform_suppressed?
            clear_transition_transform_suppression
          end
          @transition_transform_snapshots = current_snapshots
          @transition_curve_builder.invalidate if suppression_changed
          changed || suppression_changed
        rescue StandardError
          clear_transition_transform_suppression
          @transition_transform_snapshots = nil
          @transition_curve_builder.invalidate
          true
        end

        def begin_transition_topology_sync(cell_ids)
          ensure_transition_transform_state
          changed = false
          normalize_transition_cell_ids(cell_ids).each do |cell_id|
            changed = true unless @transition_transform_pending_cell_ids[cell_id]
            @transition_transform_pending_cell_ids[cell_id] = true
            @transition_transforming_cell_ids.delete(cell_id)
          end
          changed
        rescue StandardError
          false
        end

        def complete_transition_topology_sync(cell_ids)
          ensure_transition_transform_state
          changed = false
          normalize_transition_cell_ids(cell_ids).each do |cell_id|
            changed = true if @transition_transforming_cell_ids.delete(cell_id)
            changed = true if @transition_transform_pending_cell_ids.delete(cell_id)
          end
          @transition_curve_builder.invalidate if changed
          changed
        rescue StandardError
          false
        end

        def draw(view)
          return unless draw_dual_overlay?

          update_transition_transform_preview
          state_radius_scale = DualOverlayPreferences.state_radius_scale
          selected_cell_ids = selected_dual_overlay_cell_ids
          @reference_graph_debug_renderer.draw_partitions(view)
          @reference_graph_debug_renderer.draw_edges(view)
          @reference_point_debug_renderer.draw(view)

          # Draw order: Transition -> selected Transition -> State ->
          # selected State. The additional passes never modify base styling.
          unless validation_focus_active?
            excluded_cell_ids = transition_transform_excluded_cell_ids
            @transition_renderer.draw(view, excluded_cell_ids: excluded_cell_ids)
            unless selected_cell_ids.empty?
              @transition_renderer.draw_highlight(
                view,
                selected_cell_ids: selected_cell_ids,
                excluded_cell_ids: excluded_cell_ids
              )
            end
          end
          @state_renderer.draw(view, state_radius_scale: state_radius_scale)
          unless selected_cell_ids.empty?
            @state_renderer.draw_highlight(
              view,
              selected_cell_ids: selected_cell_ids,
              state_radius_scale: state_radius_scale
            )
          end
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Dual graph overlay draw failed: #{e.class}: #{e.message}"
        ensure
          view.line_width = 1 if view.respond_to?(:line_width=)
        end

        def getExtents
          bounds = Geom::BoundingBox.new
          add_dual_overlay_bounds(bounds) if draw_dual_overlay?
          bounds
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Dual graph overlay extents failed: #{e.class}: #{e.message}"
          Geom::BoundingBox.new
        end

        def overlay_state_visible?(state)
          if @indoor_model.respond_to?(:dual_overlay_state_visible?)
            return @indoor_model.dual_overlay_state_visible?(state)
          end

          return true unless @indoor_model.respond_to?(:validation_focus_active?)
          return true unless @indoor_model.validation_focus_active?

          @indoor_model.validation_focus_state?(state)
        rescue StandardError
          false
        end

        public :overlay_render_context_cache_key,
               :overlay_render_context_snapshot,
               :overlay_render_point,
               :overlay_render_point_from_snapshot,
               :overlay_render_points,
               :overlay_cell_reference_points,
               :overlay_render_vector,
               :overlay_render_vector_from_snapshot,
               :overlay_state_root_local_point,
               :rounded_point_key,
               :rounded_vector_key

        private

        # Selection highlights are only active in Edit Mode. Resolve group
        # identity from the current SketchUp selection on each draw, so
        # deselection, multi-selection, and hide/show never require cache edits.
        def selected_dual_overlay_cell_ids
          return {} if defined?(ReferenceGraphDebugMode) && !ReferenceGraphDebugMode.highlight?
          return {} unless @indoor_model.respond_to?(:editing?) && @indoor_model.editing?

          model = @indoor_model.model if @indoor_model.respond_to?(:model)
          selection = model&.selection
          return {} unless selection

          selected_group_ids = {}
          selection.each { |entity| selected_group_ids[entity.object_id] = entity }

          Array(@indoor_model.cell_spaces).each_with_object({}) do |cell, result|
            next unless cell&.valid?

            group = cell.valid_sketchup_group
            next unless group && selected_group_ids[group.object_id].equal?(group)

            cell_id = cell.id.to_s
            result[cell_id] = true unless cell_id.empty?
          end
        rescue StandardError
          {}
        end

        def update_transition_transform_preview
          ensure_transition_transform_state
          current_snapshots = selected_transition_transform_snapshots
          if @transition_transform_snapshots.nil?
            @transition_transform_snapshots = current_snapshots
            return transition_transform_suppressed?
          end

          changed_transition_transform_snapshots(@transition_transform_snapshots, current_snapshots).each do |snapshot|
            if snapshot[:kind] == :primal
              @primal_transform_preview_active = true
            else
              cell_id = snapshot[:cell_id].to_s
              @transition_transforming_cell_ids[cell_id] = true unless cell_id.empty?
            end
          end
          @transition_transform_snapshots = current_snapshots
          transition_transform_suppressed?
        rescue StandardError
          transition_transform_suppressed?
        end

        def transition_transform_snapshots_changed?(previous, current)
          !changed_transition_transform_snapshots(previous, current).empty?
        end

        def changed_transition_transform_snapshots(previous, current)
          return [] unless previous

          shared_keys = previous.keys & current.keys
          shared_keys.filter_map do |key|
            current[key] if previous[key][:transform] != current[key][:transform]
          end
        end

        def selected_transition_transform_snapshots
          model = @indoor_model.model if @indoor_model.respond_to?(:model)
          selection = model&.selection
          return {} unless selection

          watched_groups = {}
          primal_group = @indoor_model.primal_group if @indoor_model.respond_to?(:primal_group)
          watched_groups[primal_group.object_id] = { entity: primal_group, kind: :primal } if primal_group
          Array(@indoor_model.cell_spaces).each do |cell_space|
            group = cell_space&.valid_sketchup_group
            watched_groups[group.object_id] = { entity: group, kind: :cell, cell_id: cell_space.id } if group
          end

          selection.each_with_object({}) do |entity, result|
            watched = watched_groups[entity.object_id]
            next unless watched && watched[:entity].equal?(entity)
            next unless entity.respond_to?(:transformation)

            result[transition_transform_entity_key(entity)] = {
              kind: watched[:kind],
              cell_id: watched[:cell_id],
              transform: transition_transform_key(entity.transformation)
            }
          end
        rescue StandardError
          {}
        end

        def transition_transform_excluded_cell_ids
          ensure_transition_transform_state
          if @primal_transform_preview_active
            return Array(@indoor_model.cell_spaces).filter_map do |cell_space|
              normalized = cell_space&.id.to_s
              normalized unless normalized.empty?
            end
          end

          (@transition_transforming_cell_ids.keys + @transition_transform_pending_cell_ids.keys).uniq
        end

        def transition_transform_suppressed?
          ensure_transition_transform_state
          @primal_transform_preview_active == true ||
            !@transition_transforming_cell_ids.empty? ||
            !@transition_transform_pending_cell_ids.empty?
        end

        def clear_transition_transform_suppression
          ensure_transition_transform_state
          @primal_transform_preview_active = false
          @transition_transforming_cell_ids.clear
          @transition_transform_pending_cell_ids.clear
        end

        def ensure_transition_transform_state
          @transition_transforming_cell_ids ||= {}
          @transition_transform_pending_cell_ids ||= {}
          @primal_transform_preview_active = false if @primal_transform_preview_active.nil?
        end

        def normalize_transition_cell_ids(cell_ids)
          Array(cell_ids).filter_map do |cell_id|
            normalized = cell_id.to_s
            normalized unless normalized.empty?
          end.uniq
        end

        def transition_transform_entity_key(entity)
          return entity.persistent_id if entity.respond_to?(:persistent_id)

          entity.object_id
        rescue StandardError
          entity.object_id
        end

        def transition_transform_key(transformation)
          return nil unless transformation.respond_to?(:to_a)

          transformation.to_a.map { |value| value.to_f.round(6) }
        end

        def draw_dual_overlay?
          return false unless renderable_active_context?
          if @indoor_model.respond_to?(:cell_space_geometry_editing?) && @indoor_model.cell_space_geometry_editing?()
            return false
          end

          @indoor_model.dual_overlay_visible?()
        end

        def add_dual_overlay_bounds(bounds)
          extent_points = @state_renderer.overlay_state_extent_points(
            state_radius_scale: DualOverlayPreferences.state_radius_scale
          )
          extent_points.each { |point| bounds.add(point) }
          @reference_point_debug_renderer.extent_points.each { |point| bounds.add(point) }
          @reference_graph_debug_renderer.extent_points.each { |point| bounds.add(point) }
        end

        def validation_focus_active?
          @indoor_model.respond_to?(:validation_focus_active?) && @indoor_model.validation_focus_active?
        end
      end
    end
  end
end
