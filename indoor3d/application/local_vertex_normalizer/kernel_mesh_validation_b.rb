# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        def coplanar_triangle_intersection_allowed?(triangle_a, triangle_b, shared)
          normal = integer_triangle_normal(triangle_a)
          drop_axis = normal.each_index.max_by { |index| normal[index].abs }
          polygon_a = triangle_a.map { |point| project_integer_point(point, drop_axis) }
          polygon_b = triangle_b.map { |point| project_integer_point(point, drop_axis) }
          intersection = convex_polygon_intersection(polygon_a, polygon_b)
          intersection = unique_rational_points(intersection)

          return intersection.empty? if shared.empty?

          shared_projected = shared.map do |point|
            project_integer_point(point, drop_axis).map { |value| Rational(value, 1) }
          end
          if shared.length == 1
            return intersection.all? { |point| point == shared_projected[0] }
          end

          segment_start, segment_end = shared_projected
          intersection.all? do |point|
            rational_point_on_segment?(point, segment_start, segment_end)
          end && intersection.include?(segment_start) && intersection.include?(segment_end)
        end

        def convex_polygon_intersection(subject, clip)
          output = subject.map { |point| point.map { |value| Rational(value, 1) } }
          clip_points = clip.map { |point| point.map { |value| Rational(value, 1) } }
          orientation = rational_polygon_area_twice(clip_points) <=> 0
          raise ReconstructionError, 'Degenerate coplanar clipping triangle' if orientation.zero?

          clip_points.each_index do |index|
            clip_start = clip_points[index]
            clip_end = clip_points[(index + 1) % clip_points.length]
            input = output
            output = []
            break if input.empty?

            previous = input.last
            previous_value = oriented_line_value(
              clip_start,
              clip_end,
              previous,
              orientation
            )
            input.each do |current|
              current_value = oriented_line_value(
                clip_start,
                clip_end,
                current,
                orientation
              )
              previous_inside = previous_value >= 0
              current_inside = current_value >= 0

              if current_inside
                if !previous_inside
                  output << rational_line_crossing(
                    previous,
                    current,
                    previous_value,
                    current_value
                  )
                end
                output << current
              elsif previous_inside
                output << rational_line_crossing(
                  previous,
                  current,
                  previous_value,
                  current_value
                )
              end

              previous = current
              previous_value = current_value
            end
            output = remove_consecutive_rational_duplicates(output)
          end

          output
        end

        def rational_line_crossing(point_a, point_b, value_a, value_b)
          parameter = Rational(value_a, value_a - value_b)
          [
            point_a[0] + (parameter * (point_b[0] - point_a[0])),
            point_a[1] + (parameter * (point_b[1] - point_a[1]))
          ]
        end

        def oriented_line_value(line_start, line_end, point, orientation)
          orientation * rational_cross_2d(
            rational_subtract_2d(line_end, line_start),
            rational_subtract_2d(point, line_start)
          )
        end

        def rational_polygon_area_twice(points)
          points.each_index.sum do |index|
            current = points[index]
            following = points[(index + 1) % points.length]
            (current[0] * following[1]) - (current[1] * following[0])
          end
        end

        def rational_point_on_segment?(point, start_point, end_point)
          direction = rational_subtract_2d(end_point, start_point)
          offset = rational_subtract_2d(point, start_point)
          return false unless rational_cross_2d(direction, offset).zero?

          point[0] >= [start_point[0], end_point[0]].min &&
            point[0] <= [start_point[0], end_point[0]].max &&
            point[1] >= [start_point[1], end_point[1]].min &&
            point[1] <= [start_point[1], end_point[1]].max
        end

        def remove_consecutive_rational_duplicates(points)
          compact = []
          points.each { |point| compact << point if compact.empty? || compact.last != point }
          compact.pop if compact.length > 1 && compact.first == compact.last
          compact
        end

        def unique_rational_points(points)
          points.each_with_object([]) do |point, unique|
            unique << point unless unique.include?(point)
          end
        end

        def rational_subtract_2d(point_a, point_b)
          [point_a[0] - point_b[0], point_a[1] - point_b[1]]
        end

        def rational_cross_2d(vector_a, vector_b)
          (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
        end

        def project_integer_point(point, drop_axis)
          point.each_with_index.filter_map { |value, index| value unless index == drop_axis }
        end

        def integer_aabbs_overlap?(triangle_a, triangle_b)
          3.times.all? do |axis|
            range_a = triangle_a.map { |point| point[axis] }.minmax
            range_b = triangle_b.map { |point| point[axis] }.minmax
            range_a[0] <= range_b[1] && range_b[0] <= range_a[1]
          end
        end

        def canonical_triangle_key(triangle)
          triangle.sort
        end

        def canonical_edge_key(point_a, point_b)
          (point_a <=> point_b) <= 0 ? [point_a, point_b] : [point_b, point_a]
        end

        def integer_triangle_normal(triangle)
          integer_cross(
            integer_subtract(triangle[1], triangle[0]),
            integer_subtract(triangle[2], triangle[0])
          )
        end

        def integer_subtract(vector_a, vector_b)
          [
            vector_a[0] - vector_b[0],
            vector_a[1] - vector_b[1],
            vector_a[2] - vector_b[2]
          ]
        end

        def integer_dot(vector_a, vector_b)
          (vector_a[0] * vector_b[0]) +
            (vector_a[1] * vector_b[1]) +
            (vector_a[2] * vector_b[2])
        end

        def integer_cross(vector_a, vector_b)
          [
            (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
            (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
            (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
          ]
        end

        def integer_zero_vector?(vector)
          vector.all?(&:zero?)
        end

        def triangle_signature(points)
          points.map { |point| grid_indices(point) }.sort
        end

        def triangle_boundary_with_segment_vertices(points, candidates)
          boundary = []

          3.times do |index|
            start_point = points[index]
            end_point = points[(index + 1) % 3]
            boundary << start_point

            inserted = candidates.filter_map do |candidate|
              candidate_key = grid_indices(candidate)
              next if candidate_key == grid_indices(start_point)
              next if candidate_key == grid_indices(end_point)

              parameter = point_on_segment_parameter(
                candidate,
                start_point,
                end_point,
                GRID_EPSILON_MM
              )
              [parameter, candidate] if parameter
            end

            boundary.concat(inserted.sort_by(&:first).map(&:last))
          end

          remove_consecutive_duplicate_points(boundary)
        end

        # The boundary is an original triangle with optional collinear points
        # inserted on its edges, so it remains convex.
        def triangulate_convex_boundary(points, candidates = points)
          remaining = remove_consecutive_duplicate_points(points)
          return [] if remaining.length < 3
          return [remaining] if remaining.length == 3 && !collinear_triangle?(remaining)

          triangles = []
          while remaining.length > 3
            ear_index = remaining.each_index.find do |index|
              previous_point = remaining[(index - 1) % remaining.length]
              current_point = remaining[index]
              following_point = remaining[(index + 1) % remaining.length]
              triangle = [previous_point, current_point, following_point]

              !collinear_triangle?(triangle) &&
                !segment_has_interior_candidate?(
                  previous_point,
                  following_point,
                  candidates
                )
            end

            unless ear_index
              raise ReconstructionError,
                    "Could not triangulate conforming boundary: " \
                    "#{remaining.map { |point| point_components_mm(point) }.inspect}"
            end

            triangles << [
              remaining[(ear_index - 1) % remaining.length],
              remaining[ear_index],
              remaining[(ear_index + 1) % remaining.length]
            ]
            remaining.delete_at(ear_index)
          end

          triangles << remaining unless collinear_triangle?(remaining)
          triangles
        end

        def segment_has_interior_candidate?(start_point, end_point, candidates)
          start_key = grid_indices(start_point)
          end_key = grid_indices(end_point)

          candidates.any? do |candidate|
            candidate_key = grid_indices(candidate)
            next false if candidate_key == start_key || candidate_key == end_key

            !point_on_segment_parameter(
              candidate,
              start_point,
              end_point,
              GRID_EPSILON_MM
            ).nil?
          end
        end

        def triangulate_polygon(points)
          compact = remove_consecutive_duplicate_points(points)
          return [] if compact.length < 3
          return [compact] if compact.length == 3

          (1...(compact.length - 1)).map do |index|
            [compact[0], compact[index], compact[index + 1]]
          end
        end

        def remove_consecutive_duplicate_points(points)
          compact = []
          points.each do |point|
            compact << point if compact.empty? || grid_indices(compact.last) != grid_indices(point)
          end

          if compact.length > 1 && grid_indices(compact.first) == grid_indices(compact.last)
            compact.pop
          end

          compact
        end
      end
    end
  end
end
