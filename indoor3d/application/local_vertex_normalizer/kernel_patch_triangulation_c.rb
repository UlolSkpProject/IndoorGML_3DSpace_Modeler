# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        def exact_polygon_ear?(polygon, index, drop_axis)
          previous_index = (index - 1) % polygon.length
          following_index = (index + 1) % polygon.length
          point_a = integer_project_2d(polygon[previous_index], drop_axis)
          point_b = integer_project_2d(polygon[index], drop_axis)
          point_c = integer_project_2d(polygon[following_index], drop_axis)
          return false unless integer_orientation_2d(point_a, point_b, point_c).positive?

          polygon.each_index do |candidate_index|
            next if [previous_index, index, following_index].include?(candidate_index)

            candidate = integer_project_2d(polygon[candidate_index], drop_axis)
            next if candidate == point_a || candidate == point_b || candidate == point_c
            return false if integer_point_in_triangle_2d?(
              candidate,
              point_a,
              point_b,
              point_c
            )
          end

          polygon.each_index do |edge_index|
            edge_following = (edge_index + 1) % polygon.length
            next if [previous_index, index].include?(edge_index)
            next if [previous_index, following_index].include?(edge_following)

            edge_a = integer_project_2d(polygon[edge_index], drop_axis)
            edge_b = integer_project_2d(polygon[edge_following], drop_axis)
            next if edge_a == point_a || edge_b == point_a ||
                    edge_a == point_c || edge_b == point_c
            return false if integer_segments_intersect_2d?(
              point_a,
              point_c,
              edge_a,
              edge_b
            )
          end

          true
        end

        def validate_exact_patch_replacement!(
          records,
          boundary_edges,
          loop_count,
          drop_axis = nil,
          expected_area2 = nil
        )
          if records.empty?
            raise ReconstructionError, 'Exact coplanar patch triangulation returned no triangles'
          end

          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          triangles = records.map.with_index do |record, index|
            triangle = record[:points].map { |point| grid_indices(point) }
            if triangle.uniq.length != 3 || integer_zero_vector?(integer_triangle_normal(triangle))
              raise ReconstructionError,
                    "Exact coplanar patch produced a zero-area triangle: #{triangle.inspect}"
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_owners[edge] << index
            end
            triangle
          end

          replacement_boundary = edge_owners.filter_map do |edge, owners|
            edge if owners.length == 1
          end.sort
          expected_boundary = boundary_edges.map do |edge|
            canonical_edge_key(edge[0], edge[1])
          end.sort
          unless replacement_boundary == expected_boundary
            missing = expected_boundary - replacement_boundary
            added = replacement_boundary - expected_boundary
            raise TopologyChangedError,
                  "Exact coplanar retriangulation changed its constraints: " \
                  "missing=#{missing.first(10).inspect} added=#{added.first(10).inspect}"
          end

          invalid_edges = edge_owners.select do |_edge, owners|
            owners.length != 1 && owners.length != 2
          end
          unless invalid_edges.empty?
            raise TopologyChangedError,
                  "Exact coplanar retriangulation has invalid edge incidence: " \
                  "#{invalid_edges.first(10).inspect}"
          end

          vertex_count = triangles.flatten(1).uniq.length
          euler = vertex_count - edge_owners.length + triangles.length
          expected_euler = 2 - loop_count
          unless euler == expected_euler
            raise TopologyChangedError,
                  "Exact coplanar retriangulation changed patch topology: " \
                  "euler=#{euler} expected=#{expected_euler}"
          end

          if drop_axis && expected_area2
            actual_area2 = triangles.sum do |triangle|
              integer_orientation_2d(
                *triangle.map { |point| integer_project_2d(point, drop_axis) }
              ).abs
            end
            unless actual_area2 == expected_area2
              raise TopologyChangedError,
                    "Exact coplanar retriangulation changed patch area: " \
                    "area2=#{expected_area2}->#{actual_area2}"
            end
          end

          validate_triangle_intersections!(triangles)
        end

        def orient_patch_triangle(points, source_normal)
          keys = points.map { |point| grid_indices(point) }
          normal = integer_triangle_normal(keys)
          expected = Array(source_normal).map(&:to_f)
          return points unless expected.length == 3
          return points unless vector_dot(normal, expected).negative?

          [points[0], points[2], points[1]]
        end

        def integer_project_2d(point, drop_axis)
          point.each_with_index.filter_map do |coordinate, axis|
            coordinate unless axis == drop_axis
          end
        end

        def integer_polygon_area2(polygon)
          polygon.each_index.sum do |index|
            point_a = polygon[index]
            point_b = polygon[(index + 1) % polygon.length]
            (point_a[0] * point_b[1]) - (point_b[0] * point_a[1])
          end
        end

        def integer_orientation_2d(point_a, point_b, point_c)
          ((point_b[0] - point_a[0]) * (point_c[1] - point_a[1])) -
            ((point_b[1] - point_a[1]) * (point_c[0] - point_a[0]))
        end

        def integer_subtract_2d(point_a, point_b)
          [point_a[0] - point_b[0], point_a[1] - point_b[1]]
        end

        def integer_dot_2d(vector_a, vector_b)
          (vector_a[0] * vector_b[0]) + (vector_a[1] * vector_b[1])
        end

        def integer_point_on_segment_2d?(point, segment_a, segment_b)
          return false unless integer_orientation_2d(segment_a, segment_b, point).zero?

          point[0] >= [segment_a[0], segment_b[0]].min &&
            point[0] <= [segment_a[0], segment_b[0]].max &&
            point[1] >= [segment_a[1], segment_b[1]].min &&
            point[1] <= [segment_a[1], segment_b[1]].max
        end

        def integer_segments_intersect_2d?(point_a, point_b, point_c, point_d)
          orientations = [
            integer_orientation_2d(point_a, point_b, point_c),
            integer_orientation_2d(point_a, point_b, point_d),
            integer_orientation_2d(point_c, point_d, point_a),
            integer_orientation_2d(point_c, point_d, point_b)
          ]
          return true if orientations[0].zero? &&
                         integer_point_on_segment_2d?(point_c, point_a, point_b)
          return true if orientations[1].zero? &&
                         integer_point_on_segment_2d?(point_d, point_a, point_b)
          return true if orientations[2].zero? &&
                         integer_point_on_segment_2d?(point_a, point_c, point_d)
          return true if orientations[3].zero? &&
                         integer_point_on_segment_2d?(point_b, point_c, point_d)

          (orientations[0].positive? != orientations[1].positive?) &&
            (orientations[2].positive? != orientations[3].positive?)
        end

        def simple_integer_polygon_2d?(polygon)
          polygon.each_index do |first_index|
            first_following = (first_index + 1) % polygon.length
            polygon.each_index do |second_index|
              second_following = (second_index + 1) % polygon.length
              next if first_index == second_index
              next if first_following == second_index || second_following == first_index

              return false if integer_segments_intersect_2d?(
                polygon[first_index],
                polygon[first_following],
                polygon[second_index],
                polygon[second_following]
              )
            end
          end
          true
        end

        def integer_point_in_polygon_2d?(point, polygon)
          return true if polygon.each_index.any? do |index|
            integer_point_on_segment_2d?(
              point,
              polygon[index],
              polygon[(index + 1) % polygon.length]
            )
          end

          inside = false
          previous = polygon.last
          polygon.each do |current|
            crosses = (current[1] > point[1]) != (previous[1] > point[1])
            if crosses
              intersection_x = Rational(
                (previous[0] - current[0]) * (point[1] - current[1]),
                previous[1] - current[1]
              ) + current[0]
              inside = !inside if point[0] < intersection_x
            end
            previous = current
          end
          inside
        end

        def integer_point_in_triangle_2d?(point, point_a, point_b, point_c)
          orientations = [
            integer_orientation_2d(point_a, point_b, point),
            integer_orientation_2d(point_b, point_c, point),
            integer_orientation_2d(point_c, point_a, point)
          ]
          orientations.all? { |value| value >= 0 } ||
            orientations.all? { |value| value <= 0 }
        end
      end
    end
  end
end
