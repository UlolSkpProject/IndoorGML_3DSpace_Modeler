# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class StateOverlayRenderer
        # view.draw_points에 alpha값이 적용되지 않음
        DUAL_STATE_COLOR = Sketchup::Color.new(35, 120, 255, 0)
        STATE_BASE_POINT_SIZE_PIXELS = 12.0
        STATE_MIN_POINT_SIZE_PIXELS = 10
        STATE_MAX_POINT_SIZE_PIXELS = 24
        # SketchUp draw_points style 7 is a filled triangle.
        STATE_POINT_STYLE = 7

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
          @render_state_points = []
          @render_state_points_dirty = true
        end

        def draw(view, state_radius_scale: 1.0)
          rebuild_state_points if @render_state_points_dirty
          return if @render_state_points.empty?

          view.draw_points(
            @render_state_points,
            overlay_state_point_size(state_radius_scale: state_radius_scale),
            STATE_POINT_STYLE,
            DUAL_STATE_COLOR
          )
        end

        def clear_cache
          @render_state_points.clear
          @render_state_points_dirty = true
        end

        def overlay_state_point(state)
          @transform_context.overlay_render_point(@transform_context.overlay_state_root_local_point(state))
        rescue StandardError
          state.position
        end

        def overlay_state_bounds_radius(state, state_radius_scale:)
          (state.radius || State.display_radius) * state_radius_scale
        end

        def overlay_state_point_size(state_radius_scale:)
          size = STATE_BASE_POINT_SIZE_PIXELS * state_radius_scale
          size.round.clamp(STATE_MIN_POINT_SIZE_PIXELS, STATE_MAX_POINT_SIZE_PIXELS)
        end

        private

        def rebuild_state_points
          @render_state_points.clear
          @indoor_model.states.each do |state|
            next unless state&.valid?()
            next unless @transform_context.overlay_state_visible?(state)

            @render_state_points << overlay_state_point(state)
          end
          @render_state_points_dirty = false
        end
      end
    end
  end
end
