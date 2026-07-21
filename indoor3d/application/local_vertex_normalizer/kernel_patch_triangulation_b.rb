# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        def triangulate_exact_polygon_with_holes(outer, holes, drop_axis)
          polygon = outer.dup
          original_outer_2d = outer.map { |point| integer_project_2d(point, drop_axis) }
          original_holes_2d = holes.map do |hole|
            hole.map { |point| integer_project_2d(point, drop_axis) }
          end

          holes.sort_by do |hole|
            hole.map { |point| integer_project_2d(point, drop_axis)[0] }.max
          end.reverse_each do |hole|
            polygon = bridge_exact_hole(
              polygon,
              hole,
              original_outer_2d,
              original_holes_2d,
              drop_axis
            )
          end

          triangles = triangulate_exact_weak_polygon(polygon, drop_axis)
          boundary_edges = (outer.each_index.map do |index|
            canonical_edge_key(outer[index], outer[(index + 1) % outer.length])
          end + holes.flat_map do |hole|
            hole.each_index.map do |index|
              canonical_edge_key(hole[index], hole[(index + 1) % hole.length])
            end
          end).to_h { |edge| [edge, true] }

          optimize_exact_patch_triangulation(
            triangles,
            boundary_edges,
            drop_axis
          )
        end

        def bridge_exact_hole(polygon, hole, outer_2d, holes_2d, drop_axis)
          hole_index = hole.each_index.max_by do |index|
            point = integer_project_2d(hole[index], drop_axis)
            [point[0], -point[1]]
          end
          hole_point = hole[hole_index]
          hole_point_2d = integer_project_2d(hole_point, drop_axis)
          polygon_2d = polygon.map { |point| integer_project_2d(point, drop_axis) }
          all_loops = [polygon_2d] + holes_2d

          candidates = polygon.each_index.filter_map do |polygon_index|
            polygon_point = polygon[polygon_index]
            polygon_point_2d = polygon_2d[polygon_index]
            next if polygon_point_2d == hole_point_2d
            next unless exact_bridge_visible?(
              hole_point_2d,
              polygon_point_2d,
              all_loops,
              outer_2d,
              holes_2d
            )

            delta = integer_subtract_2d(polygon_point_2d, hole_point_2d)
            [integer_dot_2d(delta, delta), polygon_index]
          end
          if candidates.empty?
            raise ReconstructionError,
                  'Could not connect an exact coplanar patch hole to its exterior boundary'
          end

          polygon_index = candidates.min_by(&:first).last
          polygon_point = polygon[polygon_index]
          rotated_hole = hole[hole_index..] + hole[0...hole_index]
          polygon[0..polygon_index] +
            rotated_hole +
            [hole_point, polygon_point] +
            Array(polygon[(polygon_index + 1)..])
        end

        def exact_bridge_visible?(point_a, point_b, loops, outer, holes)
          loops.each do |loop|
            loop.each_index do |index|
              edge_a = loop[index]
              edge_b = loop[(index + 1) % loop.length]
              next if edge_a == point_a || edge_b == point_a ||
                      edge_a == point_b || edge_b == point_b
              return false if integer_segments_intersect_2d?(
                point_a,
                point_b,
                edge_a,
                edge_b
              )
            end
            loop.each do |point|
              next if point == point_a || point == point_b
              return false if integer_point_on_segment_2d?(point, point_a, point_b)
            end
          end

          midpoint = [
            Rational(point_a[0] + point_b[0], 2),
            Rational(point_a[1] + point_b[1], 2)
          ]
          return false unless integer_point_in_polygon_2d?(midpoint, outer)
          return false if holes.any? do |hole|
            integer_point_in_polygon_2d?(midpoint, hole)
          end

          true
        end

        def triangulate_exact_weak_polygon(points, drop_axis)
          remaining = points.dup
          triangles = []
          limit = remaining.length * remaining.length * 2
          attempts = 0

          while remaining.length > 3
            ear_indices = remaining.each_index.select do |index|
              exact_polygon_ear?(remaining, index, drop_axis)
            end
            ear_index = ear_indices.max_by do |index|
              exact_polygon_ear_quality(remaining, index, drop_axis)
            end
            unless ear_index
              raise ReconstructionError,
                    "Could not triangulate exact coplanar patch boundary: " \
                    "#{remaining.inspect}"
            end

            previous_point = remaining[(ear_index - 1) % remaining.length]
            current_point = remaining[ear_index]
            following_point = remaining[(ear_index + 1) % remaining.length]
            triangles << [previous_point, current_point, following_point]
            remaining.delete_at(ear_index)
            attempts += 1
            if attempts > limit
              raise ReconstructionError,
                    'Exact coplanar patch triangulation exceeded its iteration limit'
            end
          end

          final = remaining.map { |point| integer_project_2d(point, drop_axis) }
          if final.uniq.length != 3 || integer_orientation_2d(*final).zero?
            raise ReconstructionError,
                  "Exact coplanar patch ended with a zero-area triangle: #{remaining.inspect}"
          end
          triangles << remaining
          triangles
        end

        # Among all topologically valid ears, prefer the one with the greatest
        # squared minimum-altitude proxy (area^2 / longest_edge^2). This keeps a
        # short preserved boundary segment from being paired with a nearly
        # collinear third point merely because that ear appeared first.
        def exact_polygon_ear_quality(polygon, index, drop_axis)
          points = [
            polygon[(index - 1) % polygon.length],
            polygon[index],
            polygon[(index + 1) % polygon.length]
          ].map { |point| integer_project_2d(point, drop_axis) }
          area2 = integer_orientation_2d(*points).abs
          longest_edge_squared = 3.times.map do |edge_index|
            vector = integer_subtract_2d(
              points[edge_index],
              points[(edge_index + 1) % 3]
            )
            integer_dot_2d(vector, vector)
          end.max

          Rational(area2 * area2, longest_edge_squared)
        end

        # Improves the ear-clipped mesh with exact, constraint-preserving
        # Lawson flips. Only an interior diagonal shared by two triangles may
        # change. A flip is accepted when the two triangles still cover the
        # identical convex quadrilateral and their worst minimum-altitude
        # proxy strictly improves. All decisions use integer grid coordinates.
        def optimize_exact_patch_triangulation(triangles, constraints, drop_axis)
          optimized = triangles.map(&:dup)
          iteration_limit = [optimized.length * optimized.length * 2, 1].max
          iterations = 0

          loop do
            edge_owners = Hash.new { |hash, key| hash[key] = [] }
            optimized.each_with_index do |triangle, triangle_index|
              3.times do |edge_index|
                edge = canonical_edge_key(
                  triangle[edge_index],
                  triangle[(edge_index + 1) % 3]
                )
                edge_owners[edge] << triangle_index
              end
            end

            candidates = edge_owners.filter_map do |edge, owners|
              next unless owners.length == 2
              next if constraints.key?(edge)

              first_index, second_index = owners
              first = optimized[first_index]
              second = optimized[second_index]
              opposite_a = (first - edge).first
              opposite_b = (second - edge).first
              next unless opposite_a && opposite_b && opposite_a != opposite_b

              alternate_edge = canonical_edge_key(opposite_a, opposite_b)
              next if edge_owners.key?(alternate_edge)

              replacement = exact_edge_flip_replacement(
                edge,
                opposite_a,
                opposite_b,
                drop_axis
              )
              next unless replacement

              current_quality = [
                exact_integer_triangle_quality(first),
                exact_integer_triangle_quality(second)
              ].min
              replacement_quality = replacement.map do |triangle|
                exact_integer_triangle_quality(triangle)
              end.min
              next unless replacement_quality > current_quality

              [
                replacement_quality - current_quality,
                replacement_quality,
                edge,
                first_index,
                second_index,
                replacement
              ]
            end
            break if candidates.empty?

            candidate = candidates.max_by do |entry|
              [entry[0], entry[1], entry[2]]
            end
            first_index = candidate[3]
            second_index = candidate[4]
            replacement = candidate[5]
            optimized[first_index] = replacement[0]
            optimized[second_index] = replacement[1]

            iterations += 1
            if iterations > iteration_limit
              raise ReconstructionError,
                    'Exact coplanar patch edge optimization exceeded its iteration limit'
            end
          end

          optimized
        end

        def exact_edge_flip_replacement(edge, opposite_a, opposite_b, drop_axis)
          edge_a, edge_b = edge
          projected = [edge_a, edge_b, opposite_a, opposite_b].to_h do |point|
            [point, integer_project_2d(point, drop_axis)]
          end

          side_a = integer_orientation_2d(
            projected[edge_a],
            projected[edge_b],
            projected[opposite_a]
          )
          side_b = integer_orientation_2d(
            projected[edge_a],
            projected[edge_b],
            projected[opposite_b]
          )
          return nil if side_a.zero? || side_b.zero?
          return nil if side_a.positive? == side_b.positive?

          alternate_side_a = integer_orientation_2d(
            projected[opposite_a],
            projected[opposite_b],
            projected[edge_a]
          )
          alternate_side_b = integer_orientation_2d(
            projected[opposite_a],
            projected[opposite_b],
            projected[edge_b]
          )
          return nil if alternate_side_a.zero? || alternate_side_b.zero?
          return nil if alternate_side_a.positive? == alternate_side_b.positive?

          replacements = [
            [opposite_a, opposite_b, edge_a],
            [opposite_b, opposite_a, edge_b]
          ].map do |triangle|
            orientation = integer_orientation_2d(
              *triangle.map { |point| projected[point] }
            )
            return nil if orientation.zero?

            orientation.positive? ? triangle : [triangle[0], triangle[2], triangle[1]]
          end

          original_area2 = [opposite_a, opposite_b].sum do |opposite|
            integer_orientation_2d(
              projected[edge_a],
              projected[edge_b],
              projected[opposite]
            ).abs
          end
          replacement_area2 = replacements.sum do |triangle|
            integer_orientation_2d(
              *triangle.map { |point| projected[point] }
            ).abs
          end
          return nil unless replacement_area2 == original_area2

          replacements
        end

        def exact_integer_triangle_quality(triangle)
          normal = integer_triangle_normal(triangle)
          normal_squared = integer_dot(normal, normal)
          longest_edge_squared = 3.times.map do |edge_index|
            vector = integer_subtract(
              triangle[edge_index],
              triangle[(edge_index + 1) % 3]
            )
            integer_dot(vector, vector)
          end.max

          Rational(normal_squared, longest_edge_squared)
        end
      end
    end
  end
end
