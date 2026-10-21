# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TransitionCurveBuilder
        EMPTY_LINE_POINTS = [].freeze
        MIN_TRANSITION_RENDER_CACHE_LIMIT = 2048
        CURVE_CORNER_TRIM_RATIO = 0.2
        CURVE_SAMPLES_PER_CORNER = 6
        CURVE_DIRECTION_EPSILON = 1.0e-6
        WAYPOINT_NORMAL_PROJECTION_RATIO = 0.3

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
          @transition_render_segment_cache = {}
          @render_transition_line_points = nil
          @render_transition_line_points_dirty = true
          @render_transition_revision = nil
          @render_transition_exclusion_key = nil
          @render_visible_transition_segments = []
          @render_transition_generation = 0
          clear_selection_batches
        end

        def invalidate
          @render_transition_line_points = nil
          @render_transition_line_points_dirty = true
          @render_visible_transition_segments = []
          clear_selection_batches
        end

        def clear_cache
          @transition_render_segment_cache&.clear
          @render_transition_revision = nil
          @render_transition_exclusion_key = nil
          invalidate
        end

        def transition_line_points(excluded_cell_ids: nil)
          excluded_cells = transition_excluded_cell_lookup(excluded_cell_ids)
          exclusion_key = excluded_cells.keys.sort
          # Ref-Graph snapshots are immutable and replaced on regeneration.
          # Detect new snapshots even if no external overlay invalidation fired.
          revision = transition_render_revision(excluded_cells)
          if @render_transition_line_points_dirty || @render_transition_line_points.nil? ||
             @render_transition_revision != revision || @render_transition_exclusion_key != exclusion_key
            @render_transition_line_points = build_render_transition_line_points(excluded_cells)
            @render_transition_line_points_dirty = false
            @render_transition_revision = revision
            @render_transition_exclusion_key = exclusion_key
            @render_transition_generation += 1
            clear_selection_batches
          end

          @render_transition_line_points
        end

        # Keep one canonical full array. A selection change only partitions
        # cached segment references into disjoint normal/highlight arrays.
        # Native routes, curve interpolation and coordinate transforms are not
        # repeated. Empty and complete selections alias the canonical array.
        def transition_line_batches(selected_cell_ids:, excluded_cell_ids: nil)
          full_points = transition_line_points(excluded_cell_ids: excluded_cell_ids)
          selected_cells = selected_cell_lookup(selected_cell_ids)
          cache_key = [@render_transition_generation, selected_cells.keys.sort]
          return @render_selection_batches if @render_selection_batch_key == cache_key

          @render_selection_batch_key = cache_key
          @render_selection_batches = build_selection_batches(full_points, selected_cells)
        end

        def build_render_transition_line_points(excluded_cells = {})
          points = []
          accepted = []
          render_snapshot = transition_render_context_snapshot
          context_key = render_snapshot&.[](:cache_key) || transition_render_context_cache_key
          @indoor_model.transitions.each do |transition|
            next if transition_excluded?(transition, excluded_cells)
            next unless overlay_transition_visible?(transition)

            first_visible = overlay_state_visible?(transition.state1)
            second_visible = overlay_state_visible?(transition.state2)
            next unless first_visible || second_visible

            segments = cached_transition_render_segments(transition, context_key, render_snapshot)
            points.concat(segments[:default]) if first_visible && second_visible
            points.concat(segments[:first]) if first_visible
            points.concat(segments[:second]) if second_visible
            entry = {
              cell1_id: transition.cell1_id.to_s,
              cell2_id: transition.cell2_id.to_s,
              first_visible: first_visible,
              second_visible: second_visible,
              segments: segments
            }
            accepted << entry
          end
          @render_visible_transition_segments = accepted
          points
        end

        def transition_curve_segments(transition, render_snapshot = nil)
          transition_curve_segments_from_input(
            transition, transition_curve_input(transition, render_snapshot)
          )
        end

        def transition_curve_segments_from_input(_transition, curve_input)
          points = Array(curve_input[:points])
          protected_indices = Array(curve_input[:protected_indices])
          departure_directions = Hash(curve_input[:departure_directions] || {})
          waypoint_index = protected_indices.find do |index|
            index.to_i.positive? && index.to_i < points.length - 1
          end&.to_i
          unless waypoint_index
            return {
              default: rounded_polyline_segments(points, protected_indices, departure_directions),
              first: [],
              second: []
            }
          end

          first_points = points[0..waypoint_index]
          second_points = points[waypoint_index..]
          first_protected = protected_indices.filter_map do |index|
            value = index.to_i
            value if value <= waypoint_index
          end
          second_protected = protected_indices.filter_map do |index|
            value = index.to_i
            value - waypoint_index if value >= waypoint_index
          end
          first_departures = departure_directions.each_with_object({}) do |(index, direction), result|
            value = index.to_i
            result[value] = direction if value < waypoint_index
          end
          second_departures = departure_directions.each_with_object({}) do |(index, direction), result|
            value = index.to_i
            result[value - waypoint_index] = direction if value >= waypoint_index
          end

          {
            default: [],
            first: rounded_polyline_segments(first_points, first_protected, first_departures),
            second: rounded_polyline_segments(second_points, second_protected, second_departures)
          }
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
            native_curve = reference_curve(
              transition.cell1_id, transition.cell2_id, waypoint
            )
            return { points: [], protected_indices: [], departure_directions: {} } unless native_curve

            root_path.concat(native_curve)
          end
          root_path << point2

          rendered = root_path.map { |point| render_transition_point(point, render_snapshot) }
          rendered = deduplicate_consecutive_points(rendered)
          protected_indices = if waypoint
                                rendered_waypoint = render_transition_point(waypoint, render_snapshot)
                                waypoint_index = closest_point_index(rendered, rendered_waypoint)
                                waypoint_index && waypoint_index.positive? && waypoint_index < rendered.length - 1 ?
                                  [waypoint_index] : []
                              else
                                []
                              end
          departure_directions = {}
          if protected_indices.any?
            normal = waypoint_departure_normal(transition)
            rendered_normal = render_transition_vector(normal, render_snapshot) if normal
            departure_directions[protected_indices.first] = rendered_normal if rendered_normal
          end
          {
            points: rendered,
            protected_indices: protected_indices,
            departure_directions: departure_directions
          }
        end

        def polyline_segments(points)
          segments = []
          Array(points).each_cons(2) { |first, second| segments << first << second }
          segments
        end

        private

        def clear_selection_batches
          @render_selection_batch_key = nil
          @render_selection_batches = nil
        end

        def selected_cell_lookup(selected_cell_ids)
          Hash(selected_cell_ids || {}).each_with_object({}) do |(cell_id, selected), result|
            next unless selected

            normalized = cell_id.to_s
            result[normalized] = true unless normalized.empty?
          end
        rescue StandardError
          {}
        end

        def build_selection_batches(full_points, selected_cells)
          return frozen_line_batches(full_points, EMPTY_LINE_POINTS) if selected_cells.empty? || full_points.empty?

          has_normal = false
          has_highlight = false
          each_visible_segment_group(selected_cells) do |_points, selected|
            selected ? has_highlight = true : has_normal = true
            break if has_normal && has_highlight
          end
          return frozen_line_batches(full_points, EMPTY_LINE_POINTS) unless has_highlight
          return frozen_line_batches(EMPTY_LINE_POINTS, full_points) unless has_normal

          normal = []
          highlight = []
          each_visible_segment_group(selected_cells) do |points, selected|
            (selected ? highlight : normal).concat(points)
          end
          frozen_line_batches(normal.freeze, highlight.freeze)
        end

        def each_visible_segment_group(selected_cells)
          @render_visible_transition_segments.each do |entry|
            first_visible = entry[:first_visible]
            second_visible = entry[:second_visible]
            first_selected = selected_cells[entry[:cell1_id]] == true
            second_selected = selected_cells[entry[:cell2_id]] == true
            segments = entry[:segments]

            if first_visible && second_visible && !segments[:default].empty?
              yield segments[:default], first_selected || second_selected
            end
            yield segments[:first], first_selected if first_visible && !segments[:first].empty?
            yield segments[:second], second_selected if second_visible && !segments[:second].empty?
          end
        end

        def frozen_line_batches(normal, highlight)
          { normal: normal, highlight: highlight }.freeze
        end

        def reference_curve(first_cell_id, second_cell_id, waypoint)
          return nil unless @indoor_model.respond_to?(:reference_transition_curve)

          curve = @indoor_model.reference_transition_curve(
            first_cell_id, second_cell_id, waypoint
          )
          curve if curve.is_a?(Array) && !curve.empty?
        rescue StandardError
          nil
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

        # Round only genuine direction changes. Collinear Reference points stay
        # as ordinary line segments, while protected points (notably the exact
        # inter-CellSpace waypoint) remain part of the rendered path.
        def rounded_polyline_segments(points, protected_indices, departure_directions = {})
          source = Array(points)
          return [] if source.length < 2
          if source.length == 2
            segments = []
            append_path_segment(segments, source.first, source.last, departure_directions[0])
            return segments
          end

          protected = Array(protected_indices).each_with_object({}) { |index, set| set[index.to_i] = true }
          segments = []
          current = source.first
          departure_direction = departure_directions[0]

          (1...(source.length - 1)).each do |index|
            corner = source[index]
            unless protected[index] || corner_collinear?(source[index - 1], corner, source[index + 1])
              entry = interpolate_point(corner, source[index - 1], CURVE_CORNER_TRIM_RATIO)
              exit = interpolate_point(corner, source[index + 1], CURVE_CORNER_TRIM_RATIO)
              append_path_segment(segments, current, entry, departure_direction)
              departure_direction = nil

              curve_point = entry
              (1..CURVE_SAMPLES_PER_CORNER).each do |sample|
                t = sample.to_f / CURVE_SAMPLES_PER_CORNER
                next_point = quadratic_bezier_point(entry, corner, exit, t)
                append_line_segment(segments, curve_point, next_point)
                curve_point = next_point
              end
              current = exit
              next
            end

            append_path_segment(segments, current, corner, departure_direction)
            current = corner
            departure_direction = departure_directions[index]
          end

          append_path_segment(segments, current, source.last, departure_direction)
          segments
        end

        def append_path_segment(segments, first, second, departure_direction)
          return append_line_segment(segments, first, second) unless departure_direction

          append_waypoint_departure_curve(segments, first, second, departure_direction)
        end

        # Only the segment leaving the protected waypoint receives this tangent.
        # Travel straight along the face normal first, then bend toward the next
        # path point. Both distances scale with the local segment length.
        def append_waypoint_departure_curve(segments, first, second, direction)
          delta = coordinate_delta(first, second)
          distance = vector_length(delta)
          unit = normalized_coordinates(direction)
          return append_line_segment(segments, first, second) if distance <= CURVE_DIRECTION_EPSILON || !unit

          dot = 3.times.sum { |axis| unit[axis] * delta[axis] }
          unit = unit.map { |value| -value } if dot.negative?
          projected_distance = dot.abs
          tangent_magnitude = projected_distance * WAYPOINT_NORMAL_PROJECTION_RATIO
          return append_line_segment(segments, first, second) if tangent_magnitude <= CURVE_DIRECTION_EPSILON

          first_coordinates = point_coordinates(first)
          straight_coordinates = 3.times.map do |axis|
            first_coordinates[axis].to_f + unit[axis] * tangent_magnitude
          end
          straight_end = point_from_coordinates(first, straight_coordinates)
          append_line_segment(segments, first, straight_end)

          # For a quadratic Bezier, B'(0) = 2 * (control - start).
          control_distance = tangent_magnitude * 0.5
          control_coordinates = 3.times.map do |axis|
            straight_coordinates[axis] + unit[axis] * control_distance
          end
          control = point_from_coordinates(first, control_coordinates)

          curve_point = straight_end
          (1..CURVE_SAMPLES_PER_CORNER).each do |sample|
            t = sample.to_f / CURVE_SAMPLES_PER_CORNER
            next_point = quadratic_bezier_point(straight_end, control, second, t)
            append_line_segment(segments, curve_point, next_point)
            curve_point = next_point
          end
        end

        def append_line_segment(segments, first, second)
          return if point_coordinates(first) == point_coordinates(second)

          segments << first << second
        end

        def corner_collinear?(previous, corner, following)
          incoming = coordinate_delta(previous, corner)
          outgoing = coordinate_delta(corner, following)
          incoming_length = vector_length(incoming)
          outgoing_length = vector_length(outgoing)
          return true if incoming_length <= CURVE_DIRECTION_EPSILON || outgoing_length <= CURVE_DIRECTION_EPSILON

          cross = [
            incoming[1] * outgoing[2] - incoming[2] * outgoing[1],
            incoming[2] * outgoing[0] - incoming[0] * outgoing[2],
            incoming[0] * outgoing[1] - incoming[1] * outgoing[0]
          ]
          vector_length(cross) <= incoming_length * outgoing_length * CURVE_DIRECTION_EPSILON
        end

        def coordinate_delta(first, second)
          first_coordinates = point_coordinates(first)
          second_coordinates = point_coordinates(second)
          3.times.map { |axis| second_coordinates[axis].to_f - first_coordinates[axis].to_f }
        end

        def vector_length(vector)
          Math.sqrt(vector.sum { |value| value * value })
        end

        def normalized_coordinates(vector)
          coordinates = point_coordinates(vector)&.map(&:to_f)
          return nil unless coordinates&.length == 3

          length = vector_length(coordinates)
          return nil if length <= CURVE_DIRECTION_EPSILON

          coordinates.map { |value| value / length }
        rescue StandardError
          nil
        end

        def interpolate_point(first, second, ratio)
          first_coordinates = point_coordinates(first)
          second_coordinates = point_coordinates(second)
          coordinates = 3.times.map do |axis|
            first_coordinates[axis].to_f +
              (second_coordinates[axis].to_f - first_coordinates[axis].to_f) * ratio
          end
          point_from_coordinates(first, coordinates)
        end

        def quadratic_bezier_point(first, control, last, t)
          first_coordinates = point_coordinates(first)
          control_coordinates = point_coordinates(control)
          last_coordinates = point_coordinates(last)
          inverse = 1.0 - t
          coordinates = 3.times.map do |axis|
            inverse * inverse * first_coordinates[axis].to_f +
              2.0 * inverse * t * control_coordinates[axis].to_f +
              t * t * last_coordinates[axis].to_f
          end
          point_from_coordinates(first, coordinates)
        end

        def point_from_coordinates(example, coordinates)
          example.class.new(*coordinates)
        rescue StandardError
          Geom::Point3d.new(*coordinates)
        end

        def closest_point_index(points, target)
          target_coordinates = point_coordinates(target)
          return nil unless target_coordinates

          Array(points).each_with_index.min_by do |point, _index|
            coordinates = point_coordinates(point)
            3.times.sum do |axis|
              delta = coordinates[axis].to_f - target_coordinates[axis].to_f
              delta * delta
            end
          end&.last
        rescue StandardError
          nil
        end

        def waypoint_departure_normal(transition)
          return transition.selected_waypoint_normal1 if transition.respond_to?(:selected_waypoint_normal1) &&
                                                         transition.selected_waypoint_normal1
          return transition.selected_waypoint_normal2 if transition.respond_to?(:selected_waypoint_normal2) &&
                                                         transition.selected_waypoint_normal2
          return transition.selected_waypoint_normal if transition.respond_to?(:selected_waypoint_normal)

          nil
        rescue StandardError
          nil
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

          [
            context_key,
            Array(input[:points]).map { |point| point_coordinates(point) },
            Array(input[:protected_indices]),
            Hash(input[:departure_directions] || {}).sort_by { |index, _direction| index }.map do |index, direction|
              [index, point_coordinates(direction)]
            end
          ]
        rescue StandardError
          nil
        end

        def transition_render_revision(excluded_cells = {})
          [
            transition_render_context_cache_key,
            @indoor_model.transitions.filter_map do |transition|
              next if transition_excluded?(transition, excluded_cells)

              [
                transition_render_cache_identity(transition),
                point_coordinates(transition.state1_point),
                point_coordinates(transition.state2_point),
                point_coordinates(transition.selected_waypoint),
                point_coordinates(waypoint_departure_normal(transition)),
                overlay_state_visible?(transition.state1),
                overlay_state_visible?(transition.state2),
                route_snapshot_key(transition.cell1_id),
                route_snapshot_key(transition.cell2_id)
              ]
            end
          ]
        rescue StandardError
          nil
        end

        def transition_excluded_cell_lookup(cell_ids)
          Array(cell_ids).each_with_object({}) do |cell_id, result|
            normalized = cell_id.to_s
            result[normalized] = true unless normalized.empty?
          end
        end

        def transition_excluded?(transition, excluded_cells)
          return false if excluded_cells.empty?

          excluded_cells[transition.cell1_id.to_s] || excluded_cells[transition.cell2_id.to_s]
        rescue StandardError
          false
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

        def render_transition_vector(vector, render_snapshot)
          if render_snapshot && @transform_context.respond_to?(:overlay_render_vector_from_snapshot)
            return @transform_context.overlay_render_vector_from_snapshot(vector, render_snapshot)
          end
          if @transform_context.respond_to?(:overlay_render_vector)
            return @transform_context.overlay_render_vector(vector)
          end

          vector
        rescue StandardError
          vector
        end

        def overlay_transition_visible?(transition)
          if @indoor_model.respond_to?(:dual_overlay_transition_visible?)
            return @indoor_model.dual_overlay_transition_visible?(transition)
          end

          return false unless transition&.valid?

          @transform_context.overlay_state_visible?(transition.state1) ||
            @transform_context.overlay_state_visible?(transition.state2)
        rescue StandardError
          false
        end

        def overlay_state_visible?(state)
          if @indoor_model.respond_to?(:dual_overlay_state_visible?)
            return @indoor_model.dual_overlay_state_visible?(state)
          end

          @transform_context.overlay_state_visible?(state)
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
