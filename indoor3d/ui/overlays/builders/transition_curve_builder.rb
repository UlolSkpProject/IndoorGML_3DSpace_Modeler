# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TransitionCurveBuilder
        MIN_TRANSITION_RENDER_CACHE_LIMIT = 2048

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
          @transition_render_segment_cache = {}
          @render_transition_line_points = nil
          @render_transition_line_points_dirty = true
          @render_transition_revision = nil
        end

        def invalidate
          @render_transition_line_points = nil
          @render_transition_line_points_dirty = true
        end

        def clear_cache
          @transition_render_segment_cache&.clear
          @render_transition_revision = nil
          invalidate
        end

        def transition_line_points
          # Ref-Graph snapshots are immutable and replaced on regeneration.
          # Detect new snapshots even if no external overlay invalidation fired.
          revision = transition_render_revision
          if @render_transition_line_points_dirty || @render_transition_line_points.nil? ||
             @render_transition_revision != revision
            @render_transition_line_points = build_render_transition_line_points
            @render_transition_line_points_dirty = false
            @render_transition_revision = revision
          end

          @render_transition_line_points
        end

        def build_render_transition_line_points
          points = []
          render_snapshot = transition_render_context_snapshot
          context_key = render_snapshot&.[](:cache_key) || transition_render_context_cache_key
          @indoor_model.transitions.each do |transition|
            next unless overlay_transition_visible?(transition)

            segments = cached_transition_render_segments(transition, context_key, render_snapshot)
            points.concat(segments[:default])
            points.concat(segments[:first])
            points.concat(segments[:second])
          end
          points
        end

        def transition_curve_segments(transition, render_snapshot = nil)
          transition_curve_segments_from_input(
            transition, transition_curve_input(transition, render_snapshot)
          )
        end

        def transition_curve_segments_from_input(_transition, curve_input)
          { default: polyline_segments(Array(curve_input[:points])), first: [], second: [] }
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Transition line build failed: #{e.class}: #{e.message}"
          empty_transition_segment_groups
        end

        # All coordinates here are root-local until one common render transform
        # is applied. The exact Transition endpoints are retained independently
        # of the selected State reference node.
        def transition_curve_input(transition, render_snapshot = nil)
          point1 = transition.state1_point || @transform_context.overlay_state_root_local_point(transition.state1)
          point2 = transition.state2_point || @transform_context.overlay_state_root_local_point(transition.state2)
          waypoint = transition.selected_waypoint

          root_path = [point1]
          if waypoint
            first = reference_path(transition.cell1_id, waypoint)
            second = reference_path(transition.cell2_id, waypoint)
            root_path.concat(first) if first
            root_path << waypoint
            root_path.concat(second.reverse) if second
          end
          root_path << point2

          rendered = root_path.map { |point| render_transition_point(point, render_snapshot) }
          { points: deduplicate_consecutive_points(rendered) }
        end

        def polyline_segments(points)
          segments = []
          Array(points).each_cons(2) { |first, second| segments << first << second }
          segments
        end

        private

        def reference_path(cell_id, waypoint)
          return nil unless @indoor_model.respond_to?(:reference_graph_path_to_waypoint)

          path = @indoor_model.reference_graph_path_to_waypoint(cell_id, waypoint)
          path if path.is_a?(Array) && !path.empty?
        rescue StandardError
          nil # A missing/bad route affects only its own CellSpace side.
        end

        def deduplicate_consecutive_points(points)
          result = []
          last = points.length - 1
          points.each_with_index do |point, index|
            if !result.empty? && point_coordinates(result.last) == point_coordinates(point)
              # Preserve the exact final State2 endpoint, even if it matches
              # the last reference node by coordinates.
              result[-1] = point if index == last && result.length > 1
            else
              result << point
            end
          end
          result
        end

        def cached_transition_render_segments(transition, context_key, render_snapshot)
          input = transition_curve_input(transition, render_snapshot)
          fingerprint = transition_render_fingerprint(input, context_key)
          identity = transition_render_cache_identity(transition)
          if fingerprint
            cached = @transition_render_segment_cache[identity]
            return cached[:segments] if cached && cached[:fingerprint] == fingerprint
          end

          segments = transition_curve_segments_from_input(transition, input)
          if fingerprint
            @transition_render_segment_cache.clear if @transition_render_segment_cache.length > transition_render_cache_limit
            @transition_render_segment_cache[identity] = { fingerprint: fingerprint, segments: segments }
          end
          segments
        end

        def transition_render_fingerprint(input, context_key)
          return nil if context_key.nil?

          [context_key, Array(input[:points]).map { |point| point_coordinates(point) }]
        rescue StandardError
          nil
        end

        def transition_render_revision
          [
            transition_render_context_cache_key,
            @indoor_model.transitions.map do |transition|
              [
                transition_render_cache_identity(transition),
                point_coordinates(transition.state1_point),
                point_coordinates(transition.state2_point),
                point_coordinates(transition.selected_waypoint),
                route_snapshot_key(transition.cell1_id),
                route_snapshot_key(transition.cell2_id)
              ]
            end
          ]
        rescue StandardError
          nil
        end

        def route_snapshot_key(cell_id)
          return nil unless @indoor_model.respond_to?(:reference_graph_route_snapshot_key_for)

          @indoor_model.reference_graph_route_snapshot_key_for(cell_id)
        end

        def point_coordinates(point)
          point && [point.x, point.y, point.z]
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

        def transition_render_cache_limit
          [@indoor_model.transitions.length * 2, MIN_TRANSITION_RENDER_CACHE_LIMIT].max
        rescue StandardError
          MIN_TRANSITION_RENDER_CACHE_LIMIT
        end
      end
    end
  end
end
