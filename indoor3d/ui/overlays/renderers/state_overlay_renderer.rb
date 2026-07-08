# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class StateOverlayRenderer
        DUAL_STATE_COLOR = Sketchup::Color.new(35, 120, 255, 255)
        STATE_CIRCLE_SEGMENTS = 8
        UNIT_CIRCLE = (0...STATE_CIRCLE_SEGMENTS).map do |i|
          angle = (2.0 * Math::PI * i) / STATE_CIRCLE_SEGMENTS
          [Math.cos(angle), Math.sin(angle)]
        end.freeze
        OVERLAY_RADIUS_SCALE = 1.0
        STATE_MIN_RADIUS_PIXELS = 5.0
        STATE_MAX_RADIUS_PIXELS = 10.0

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
          @render_state_triangle_points = []
        end

        def draw(view)
          view.drawing_color = DUAL_STATE_COLOR
          right_axis, up_axis = @transform_context.camera_billboard_axes(view)
          dir_axis = view.camera.direction.clone
          @render_state_triangle_points ||= []
          @render_state_triangle_points.clear
          @indoor_model.states.each do |state|
            next unless state&.valid?()
            next unless @transform_context.overlay_state_visible?(state)

            center = overlay_state_point(state)
            radius = overlay_state_radius(view, center, state)
            @render_state_triangle_points.concat(
              billboard_disk_triangle_points(center, right_axis, up_axis, dir_axis, radius)
            )
          end
          view.draw(GL_TRIANGLES, @render_state_triangle_points) unless @render_state_triangle_points.empty?
        end

        def clear_cache
          @render_state_triangle_points&.clear
        end

        def overlay_state_point(state)
          @transform_context.overlay_render_point(@transform_context.overlay_state_root_local_point(state))
        rescue StandardError
          state.position
        end

        def overlay_state_radius(view, center, state)
          degree_scale = overlay_state_degree_scale(state)
          model_radius = (state.radius || State.display_radius) * OVERLAY_RADIUS_SCALE * degree_scale
          clamp_overlay_radius(view, center, model_radius)
        end

        def overlay_state_degree_scale(state)
          transition_count = state.transitions.count { |transition| transition&.valid? }
          scale = 1.0 + (Math.sqrt([transition_count - 1, 0].max) * 0.12)
          [scale, 1.45].min
        end

        def billboard_disk_triangle_points(center, right_axis, up_axis, dir_axis, radius)
          points = UNIT_CIRCLE.map do |cos_a, sin_a|
            Geom::Point3d.new(
              (center.x - radius * dir_axis.x) + (right_axis.x * cos_a * radius) + (up_axis.x * sin_a * radius),
              (center.y - radius * dir_axis.y) + (right_axis.y * cos_a * radius) + (up_axis.y * sin_a * radius),
              (center.z - radius * dir_axis.z) + (right_axis.z * cos_a * radius) + (up_axis.z * sin_a * radius)
            )
          end
          points.each_with_index.flat_map do |point, index|
            [center, point, points[(index + 1) % STATE_CIRCLE_SEGMENTS]]
          end
        end

        private

        def clamp_overlay_radius(view, center, model_radius)
          screen_min_radius = view.pixels_to_model(STATE_MIN_RADIUS_PIXELS, center) * 0.3
          screen_max_radius = view.pixels_to_model(STATE_MAX_RADIUS_PIXELS, center) * 0.3
          [[model_radius, screen_min_radius].max, screen_max_radius].min
        end
      end
    end
  end
end
