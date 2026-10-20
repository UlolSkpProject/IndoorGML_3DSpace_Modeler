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
          @transition_transform_keys = nil
          @transition_transform_preview_active = false
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows IndoorGML state and transition geometry.')
        end

        def invalidate_transition_points
          @transition_curve_builder.invalidate
          @state_renderer.clear_cache
        end

        # A selected CellSpace/Primal transform is tracked without rebuilding
        # Transition geometry. ModelObserver calls this after commit/abort so the
        # next draw performs exactly one rebuild at the final transformation.
        def finish_transition_transform_preview
          changed = @transition_transform_preview_active == true || selected_transition_transform_changed?
          @transition_transform_preview_active = false
          @transition_transform_keys = selected_transition_transform_keys
          @transition_curve_builder.invalidate if changed
          changed
        rescue StandardError
          @transition_transform_preview_active = false
          @transition_transform_keys = nil
          @transition_curve_builder.invalidate
          true
        end

        def draw(view)
          return unless draw_dual_overlay?

          transition_transforming = update_transition_transform_preview
          state_radius_scale = DualOverlayPreferences.state_radius_scale
          @reference_graph_debug_renderer.draw_partitions(view)
          @transition_renderer.draw(view) unless validation_focus_active? || transition_transforming
          @reference_graph_debug_renderer.draw_edges(view)
          @reference_point_debug_renderer.draw(view)
          @state_renderer.draw(view, state_radius_scale: state_radius_scale)
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

        def update_transition_transform_preview
          current_keys = selected_transition_transform_keys
          if @transition_transform_keys.nil?
            @transition_transform_keys = current_keys
            return @transition_transform_preview_active == true
          end

          @transition_transform_preview_active = true if transition_transform_keys_changed?(
            @transition_transform_keys, current_keys
          )
          @transition_transform_keys = current_keys
          @transition_transform_preview_active == true
        rescue StandardError
          @transition_transform_preview_active == true
        end

        def selected_transition_transform_changed?
          return false if @transition_transform_keys.nil?

          transition_transform_keys_changed?(
            @transition_transform_keys,
            selected_transition_transform_keys
          )
        end

        def transition_transform_keys_changed?(previous, current)
          shared_keys = previous.keys & current.keys
          shared_keys.any? { |key| previous[key] != current[key] }
        end

        def selected_transition_transform_keys
          model = @indoor_model.model if @indoor_model.respond_to?(:model)
          selection = model&.selection
          return {} unless selection

          watched_groups = {}
          primal_group = @indoor_model.primal_group if @indoor_model.respond_to?(:primal_group)
          watched_groups[primal_group.object_id] = primal_group if primal_group
          Array(@indoor_model.cell_spaces).each do |cell_space|
            group = cell_space&.valid_sketchup_group
            watched_groups[group.object_id] = group if group
          end

          selection.each_with_object({}) do |entity, result|
            watched = watched_groups[entity.object_id]
            next unless watched&.equal?(entity)
            next unless entity.respond_to?(:transformation)

            result[transition_transform_entity_key(entity)] = transition_transform_key(entity.transformation)
          end
        rescue StandardError
          {}
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
