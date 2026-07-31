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
          @render_states = []
          @render_state_points = []
          @render_state_points_dirty = true
          clear_extent_cache
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
          @render_states.clear
          @render_state_points.clear
          @render_state_points_dirty = true
          clear_extent_cache
        end

        def overlay_state_point(state)
          @transform_context.overlay_render_point(@transform_context.overlay_state_root_local_point(state))
        rescue StandardError
          state.position
        end

        def overlay_state_bounds_radius(state, state_radius_scale:)
          (state.radius || State.display_radius) * state_radius_scale
        end

        def overlay_state_extent_points(state_radius_scale:)
          rebuild_state_points if @render_state_points_dirty
          return [] if @render_state_points.empty?

          scale = state_radius_scale.to_f
          return @render_state_extent_points if @render_state_extent_scale == scale

          min_x = nil
          min_y = nil
          min_z = nil
          max_x = nil
          max_y = nil
          max_z = nil

          @render_state_points.each_with_index do |point, index|
            state = @render_states[index]
            radius = overlay_state_bounds_radius(state, state_radius_scale: scale)
            low_x = point.x - radius
            low_y = point.y - radius
            low_z = point.z - radius
            high_x = point.x + radius
            high_y = point.y + radius
            high_z = point.z + radius

            min_x = low_x if min_x.nil? || low_x < min_x
            min_y = low_y if min_y.nil? || low_y < min_y
            min_z = low_z if min_z.nil? || low_z < min_z
            max_x = high_x if max_x.nil? || high_x > max_x
            max_y = high_y if max_y.nil? || high_y > max_y
            max_z = high_z if max_z.nil? || high_z > max_z
          end

          @render_state_extent_scale = scale
          @render_state_extent_points = [
            Geom::Point3d.new(min_x, min_y, min_z),
            Geom::Point3d.new(max_x, max_y, max_z)
          ]
        end

        def overlay_state_point_size(state_radius_scale:)
          size = STATE_BASE_POINT_SIZE_PIXELS * state_radius_scale
          size.round.clamp(STATE_MIN_POINT_SIZE_PIXELS, STATE_MAX_POINT_SIZE_PIXELS)
        end

        private

        def rebuild_state_points
          @render_states.clear
          @render_state_points.clear
          clear_extent_cache
          @indoor_model.states.each do |state|
            next unless state&.valid?()
            next unless @transform_context.overlay_state_visible?(state)

            @render_states << state
            @render_state_points << overlay_state_point(state)
          end
          @render_state_points_dirty = false
        end

        def clear_extent_cache
          @render_state_extent_scale = nil
          @render_state_extent_points = []
        end
      end
    end
  end
end
