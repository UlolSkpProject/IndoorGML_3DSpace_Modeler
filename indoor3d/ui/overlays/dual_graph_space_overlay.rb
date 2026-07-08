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
          @state_renderer = StateOverlayRenderer.new(indoor_model: @indoor_model, transform_context: self)
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows IndoorGML state and transition geometry.')
        end

        def invalidate_transition_points
          @transition_curve_builder.invalidate
          @state_renderer.clear_cache
        end

        def draw(view)
          return unless draw_dual_overlay?

          state_radius_scale = DualOverlayPreferences.state_radius_scale
          @transition_renderer.draw(view) unless validation_focus_active?
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

        public :camera_billboard_axes,
               :overlay_render_context_cache_key,
               :overlay_render_point,
               :overlay_render_vector,
               :overlay_state_root_local_point,
               :rounded_point_key,
               :rounded_vector_key

        private

        def draw_dual_overlay?
          return false unless renderable_active_context?
          if @indoor_model.respond_to?(:cell_space_geometry_editing?) && @indoor_model.cell_space_geometry_editing?()
            return false
          end

          @indoor_model.dual_overlay_visible?()
        end

        def add_dual_overlay_bounds(bounds)
          state_radius_scale = DualOverlayPreferences.state_radius_scale
          @indoor_model.states.each do |state|
            next unless state&.valid?()
            next unless overlay_state_visible?(state)

            point = @state_renderer.overlay_state_point(state)
            radius = @state_renderer.overlay_state_bounds_radius(
              state,
              state_radius_scale: state_radius_scale
            )
            bounds.add(
              Geom::Point3d.new(point.x - radius, point.y - radius, point.z - radius),
              Geom::Point3d.new(point.x + radius, point.y + radius, point.z + radius)
            )
          end
        end

        def validation_focus_active?
          @indoor_model.respond_to?(:validation_focus_active?) && @indoor_model.validation_focus_active?
        end
      end
    end
  end
end
