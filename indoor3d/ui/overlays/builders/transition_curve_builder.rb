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
          @transition_render_segment_cache = {}
          @render_transition_line_points = nil
          @render_transition_line_points_dirty = true
        end

        # Invalidates only the assembled GL_LINES render list. Per-transition
        # render segments remain content-addressed by their geometric inputs and
        # already contain any generated Hermite geometry, so unchanged
        # transitions can be reused directly.
        def invalidate
          @render_transition_line_points = nil
          @render_transition_line_points_dirty = true
        end

        # Explicit hard reset for lifecycle/reload/debug cases that need all
        # per-transition render geometry released immediately.
        def clear_cache
          @transition_render_segment_cache&.clear
          invalidate
        end

        def transition_line_points
          if @render_transition_line_points_dirty || @render_transition_line_points.nil?
            @render_transition_line_points = build_render_transition_line_points
            @render_transition_line_points_dirty = false
          end

          @render_transition_line_points
        end

        def build_render_transition_line_points
          points = []
          render_snapshot = transition_render_context_snapshot
          render_context_key = render_snapshot&.[](:cache_key) || transition_render_context_cache_key
          @indoor_model.transitions.each do |transition|
            # Renderability is the single validity/visibility gate. Production
            # IndoorModel#dual_overlay_transition_visible? validates Transition
            # and endpoint States, so repeating the same checks here multiplies
            # expensive CellSpace#valid? / manifold? calls for every frame rebuild.
            next unless overlay_transition_visible?(transition)

            segments = cached_transition_render_segments(transition, render_context_key, render_snapshot)
            points.concat(segments[:default])
            points.concat(segments[:first])
            points.concat(segments[:second])
          end
          points
        end

        def transition_curve_segments(transition, render_snapshot = nil)
          transition_curve_segments_from_input(
            transition,
            transition_curve_input(transition, render_snapshot)
          )
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

        # The render-segment cache is the effective per-transition geometry cache.
        # Keeping a second cache for the intermediate Hermite point groups only
        # adds key construction/hash allocation on hard rebuilds: soft rebuilds
        # hit @transition_render_segment_cache before this method is reached.
        def cached_transition_curve_point_groups(_transition, curve_input)
          control_points = curve_input[:points]
          return { default: control_points, first: [], second: [] } if control_points.length < 3

          if curve_input[:normal1] && curve_input[:normal2]
            hermite_transition_curve_point_groups(
              control_points,
              curve_input[:normal1],
              curve_input[:normal2]
            )
          else
            { default: control_points, first: [], second: [] }
          end
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

        def transition_curve_input(transition, render_snapshot = nil)
          point1 = render_transition_point(
            transition.state1_point || @transform_context.overlay_state_root_local_point(transition.state1),
            render_snapshot
          )
          point2 = render_transition_point(
            transition.state2_point || @transform_context.overlay_state_root_local_point(transition.state2),
            render_snapshot
          )
          return { points: [], normal1: nil, normal2: nil } if point1.distance(point2) <= 0.001

          waypoint = transition.selected_waypoint
          points = waypoint ? [point1, render_transition_point(waypoint, render_snapshot), point2] : [point1, point2]
          {
            points: points,
            normal1: normalized_transition_normal(
              render_transition_vector(transition.selected_waypoint_normal1, render_snapshot)
            ),
            normal2: normalized_transition_normal(
              render_transition_vector(transition.selected_waypoint_normal2, render_snapshot)
            )
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
          segments = []
          index = 0
          last_index = points.length - 1
          while index < last_index
            segments << points[index] << points[index + 1]
            index += 1
          end
          segments
        end

        private

        def cached_transition_render_segments(transition, render_context_key, render_snapshot)
          fingerprint = transition_render_fingerprint(transition, render_context_key)
          cache_key = transition_render_cache_identity(transition)
          if fingerprint
            cached = @transition_render_segment_cache[cache_key]
            return cached[:segments] if cached && cached[:fingerprint] == fingerprint
          end

          segments = transition_curve_segments(transition, render_snapshot)
          if fingerprint
            @transition_render_segment_cache.clear if @transition_render_segment_cache.length > transition_curve_cache_limit
            @transition_render_segment_cache[cache_key] = {
              fingerprint: fingerprint,
              segments: segments
            }
          end
          segments
        end

        def transition_render_fingerprint(transition, render_context_key)
          return nil if render_context_key.nil?

          point1 = transition.state1_point || @transform_context.overlay_state_root_local_point(transition.state1)
          point2 = transition.state2_point || @transform_context.overlay_state_root_local_point(transition.state2)
          [
            render_context_key,
            @transform_context.rounded_point_key(point1),
            @transform_context.rounded_point_key(point2),
            @transform_context.rounded_point_key(transition.selected_waypoint),
            @transform_context.rounded_vector_key(transition.selected_waypoint_normal1),
            @transform_context.rounded_vector_key(transition.selected_waypoint_normal2)
          ]
        rescue StandardError
          nil
        end

        def transition_render_cache_identity(transition)
          id = transition.id
          id.to_s.empty? ? transition.object_id : id
        rescue StandardError
          transition.object_id
        end

        def transition_render_context_snapshot
          return nil unless @transform_context.respond_to?(:overlay_render_context_snapshot)

          snapshot = @transform_context.overlay_render_context_snapshot
          snapshot.is_a?(Hash) ? snapshot : nil
        rescue StandardError
          nil
        end

        def transition_render_context_cache_key
          return nil unless @transform_context.respond_to?(:overlay_render_context_cache_key)

          @transform_context.overlay_render_context_cache_key
        rescue StandardError
          nil
        end

        def render_transition_point(point, render_snapshot)
          if render_snapshot && @transform_context.respond_to?(:overlay_render_point_from_snapshot)
            return @transform_context.overlay_render_point_from_snapshot(point, render_snapshot)
          end

          @transform_context.overlay_render_point(point)
        end

        def render_transition_vector(vector, render_snapshot)
          if render_snapshot && @transform_context.respond_to?(:overlay_render_vector_from_snapshot)
            return @transform_context.overlay_render_vector_from_snapshot(vector, render_snapshot)
          end

          @transform_context.overlay_render_vector(vector)
        end

        def overlay_transition_visible?(transition)
          if @indoor_model.respond_to?(:dual_overlay_transition_visible?)
            return @indoor_model.dual_overlay_transition_visible?(transition)
          end

          return false unless transition&.valid?

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
