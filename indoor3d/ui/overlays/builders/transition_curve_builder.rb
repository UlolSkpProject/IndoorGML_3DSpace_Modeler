# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TransitionCurveBuilder
        TRANSITION_MIN_CURVE_SEGMENTS = 3
        TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS = 6
        TRANSITION_CURVE_SEGMENTS = 9
        MIN_TRANSITION_CURVE_CACHE_LIMIT = 2048

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
          @transition_curve_cache = {}
          @render_transition_line_points = nil
          @render_transition_line_points_key = nil
        end

        def invalidate
          @transition_curve_cache&.clear
          @render_transition_line_points = nil
          @render_transition_line_points_key = nil
        end

        def transition_line_points
          transition_line_points_with_key.first
        end

        def transition_line_points_with_key
          cache_key = render_transition_line_points_cache_key
          if @render_transition_line_points.nil? || @render_transition_line_points_key != cache_key
            @render_transition_line_points = build_render_transition_line_points
            @render_transition_line_points_key = cache_key
          end
          [@render_transition_line_points, @render_transition_line_points_key]
        end

        def render_transition_line_points_cache_key
          [
            @transform_context.overlay_render_context_cache_key,
            @indoor_model.transitions.map do |transition|
              next nil unless transition&.valid?

              [
                transition.id,
                @transform_context.rounded_point_key(transition.state1_point || @transform_context.overlay_state_root_local_point(transition.state1)),
                @transform_context.rounded_point_key(transition.state2_point || @transform_context.overlay_state_root_local_point(transition.state2)),
                @transform_context.rounded_point_key(transition.selected_waypoint),
                @transform_context.rounded_vector_key(transition.selected_waypoint_normal1),
                @transform_context.rounded_vector_key(transition.selected_waypoint_normal2)
              ]
            end.compact
          ]
        end

        def build_render_transition_line_points
          points = []
          @indoor_model.transitions.each do |transition|
            next unless transition&.valid?
            next unless transition.state1&.valid? && transition.state2&.valid?
            next unless overlay_transition_visible?(transition)

            segments = transition_curve_segments(transition)
            points.concat(segments[:default])
            points.concat(segments[:first])
            points.concat(segments[:second])
          end
          points
        end

        def transition_curve_segments(transition)
          transition_curve_segments_from_input(transition, transition_curve_input(transition))
        end

        def transition_curve_segments_from_input(transition, curve_input)
          control_points = []
          control_points = curve_input[:points]
          return empty_transition_segment_groups if control_points.length < 2

          curve_point_groups = cached_transition_curve_point_groups(transition, curve_input)
          {
            default: polyline_segments(curve_point_groups[:default]),
            first: polyline_segments(curve_point_groups[:first]),
            second: polyline_segments(curve_point_groups[:second])
          }
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Transition curve build failed: #{e.class}: #{e.message}"
          { default: polyline_segments(control_points || []), first: [], second: [] }
        end

        def cached_transition_curve_point_groups(transition, curve_input)
          control_points = curve_input[:points]
          return { default: control_points, first: [], second: [] } if control_points.length < 3

          @transition_curve_cache ||= {}
          key = transition_curve_cache_key(transition, curve_input)
          cached = @transition_curve_cache[key]
          return cached if cached

          @transition_curve_cache.clear if @transition_curve_cache.length > transition_curve_cache_limit
          groups = curve_input[:normal1] && curve_input[:normal2] ?
            hermite_transition_curve_point_groups(control_points, curve_input[:normal1], curve_input[:normal2]) :
            { default: control_points, first: [], second: [] }
          @transition_curve_cache[key] = groups
          groups
        end

        def transition_curve_cache_key(transition, curve_input)
          [
            transition.id,
            curve_input[:points].map { |point| @transform_context.rounded_point_key(point) },
            @transform_context.rounded_vector_key(curve_input[:normal1]),
            @transform_context.rounded_vector_key(curve_input[:normal2])
          ]
        rescue StandardError
          [transition.id, Time.now.to_f]
        end

        def hermite_transition_curve_point_groups(control_points, normal1, normal2)
          return { default: control_points, first: [], second: [] } unless control_points.length == 3

          point1, waypoint, point2 = control_points
          unless normal1.is_a?(Geom::Vector3d) && normal1.length > 0.001 &&
                 normal2.is_a?(Geom::Vector3d) && normal2.length > 0.001
            return { default: control_points, first: [], second: [] }
          end

          dir1 = point1.vector_to(waypoint)
          dir2 = point2.vector_to(waypoint)
          tangent1_mag = dir1.length
          tangent2_mag = dir2.length
          return { default: control_points, first: [], second: [] } if tangent1_mag <= 0.001 || tangent2_mag <= 0.001

          first_waypoint_tangent = scaled_normal(normal1, tangent1_mag * tangent_angle_weight(dir1, normal1))
          second_waypoint_tangent = scaled_normal(normal2, tangent2_mag * tangent_angle_weight(dir2, normal2))

          first_start_tangent = scaled_vector(point1, waypoint, 2.0)
          first_end_tangent = first_waypoint_tangent
          second_start_tangent = scaled_vector(point2, waypoint, 2.0)
          second_end_tangent = second_waypoint_tangent
          first_segment_count = transition_curve_segment_count(dir1, normal1)
          second_segment_count = transition_curve_segment_count(dir2, normal2)

          first_segment = Utils::Math::HermiteSpline.generate_segment(
            point1,
            waypoint,
            first_start_tangent,
            first_end_tangent,
            first_segment_count
          )
          second_segment = Utils::Math::HermiteSpline.generate_segment(
            point2,
            waypoint,
            second_start_tangent,
            second_end_tangent,
            second_segment_count
          )
          { default: [], first: first_segment, second: second_segment }
        end

        def transition_curve_input(transition)
          point1 = @transform_context.overlay_render_point(
            transition.state1_point || @transform_context.overlay_state_root_local_point(transition.state1)
          )
          point2 = @transform_context.overlay_render_point(
            transition.state2_point || @transform_context.overlay_state_root_local_point(transition.state2)
          )
          return { points: [], normal1: nil, normal2: nil } if point1.distance(point2) <= 0.001

          waypoint = transition.selected_waypoint
          points = waypoint ? [point1, @transform_context.overlay_render_point(waypoint), point2] : [point1, point2]
          {
            points: points,
            normal1: normalized_transition_normal(@transform_context.overlay_render_vector(transition.selected_waypoint_normal1)),
            normal2: normalized_transition_normal(@transform_context.overlay_render_vector(transition.selected_waypoint_normal2))
          }
        end

        def transition_curve_segment_count(direction, waypoint_direction)
          angle = vector_angle_degrees(direction, waypoint_direction)
          return TRANSITION_CURVE_SEGMENTS if angle.nil?

          segments =
            if angle <= 90.0
              TRANSITION_MIN_CURVE_SEGMENTS +
                ((angle / 90.0) * (TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS - TRANSITION_MIN_CURVE_SEGMENTS))
            else
              TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS -
                (((angle - 90.0) / 90.0) * (TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS - TRANSITION_CURVE_SEGMENTS))
            end
          segments.round.clamp(TRANSITION_MIN_CURVE_SEGMENTS, TRANSITION_CURVE_SEGMENTS)
        end

        def vector_angle_degrees(vector1, vector2)
          return nil unless vector1.is_a?(Geom::Vector3d) && vector2.is_a?(Geom::Vector3d)
          return nil if vector1.length <= 0.001 || vector2.length <= 0.001

          first = vector1.clone
          second = vector2.clone
          first.normalize!
          second.normalize!
          dot = [[first.dot(second), -1.0].max, 1.0].min
          Math.acos(dot) * 180.0 / Math::PI
        end

        def polyline_segments(points)
          points.each_cons(2).flat_map { |from, to| [from, to] }
        end

        private

        def overlay_transition_visible?(transition)
          if @indoor_model.respond_to?(:dual_overlay_transition_visible?)
            return @indoor_model.dual_overlay_transition_visible?(transition)
          end

          @transform_context.overlay_state_visible?(transition.state1) &&
            @transform_context.overlay_state_visible?(transition.state2)
        rescue StandardError
          false
        end

        def empty_transition_segment_groups
          { default: [], first: [], second: [] }
        end

        def transition_curve_cache_limit
          transition_count = @indoor_model.transitions.length
          [transition_count * 2, MIN_TRANSITION_CURVE_CACHE_LIMIT].max
        rescue StandardError
          MIN_TRANSITION_CURVE_CACHE_LIMIT
        end

        def scaled_normal(normal, magnitude)
          tangent = normal.clone
          tangent.normalize!
          tangent.length = magnitude
          tangent
        end

        def tangent_angle_weight(direction, normal)
          dir = direction.clone
          norm = normal.clone
          dir.normalize!
          norm.normalize!
          dot = [[dir.dot(norm), -1.0].max, 1.0].min
          0.55 - (0.45 * dot)
        end

        def scaled_vector(from, to, scale)
          vector = from.vector_to(to)
          vector.length = vector.length * scale if vector.length > 0.001
          vector
        end

        def normalized_transition_normal(vector)
          return nil unless vector.is_a?(Geom::Vector3d)

          normal = vector.clone
          normal.normalize! if normal.length > 0.001
          normal
        rescue StandardError
          nil
        end
      end
    end
  end
end
