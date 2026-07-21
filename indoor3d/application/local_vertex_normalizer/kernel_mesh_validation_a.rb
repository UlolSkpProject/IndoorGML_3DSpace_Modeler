# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # Validates the snapped surface as an exact integer-grid triangle
        # complex before any SketchUp entities are erased. Integer arithmetic
        # avoids introducing a second geometric tolerance into normalization.
        def validate_normalized_triangle_shapes!(triangle_records)
          triangle_records.each_with_index do |record, index|
            triangle = record[:points].map { |point| grid_indices(point) }
            next if triangle.uniq.length == 3 &&
                    !integer_zero_vector?(integer_triangle_normal(triangle))

            raise ReconstructionError,
                  "Grid projection collapses source triangle #{index}: #{triangle.inspect}"
          end
        end

        def validate_normalized_triangle_mesh!(triangle_records)
          validation = validate_normalized_triangle_topology!(triangle_records)
          triangles = triangle_records.map do |record|
            record[:points].map { |point| grid_indices(point) }
          end
          tested_pairs = validate_triangle_intersections!(triangles)

          validation.merge(tested_triangle_pairs: tested_pairs)
        end

        # Validates only the combinatorial closed-manifold invariants. Geometry
        # intersections are deliberately checked after exact coplanar patches
        # have been reconstructed from their preserved boundary constraints.
        def validate_normalized_triangle_topology!(triangle_records)
          triangles = triangle_records.map do |record|
            record[:points].map { |point| grid_indices(point) }
          end
          raise ReconstructionError, 'Normalized triangle mesh is empty' if triangles.empty?

          signatures = {}
          edge_incidence = Hash.new { |hash, key| hash[key] = [] }
          vertices = {}

          triangles.each_with_index do |triangle, triangle_index|
            if triangle.uniq.length != 3 || integer_zero_vector?(integer_triangle_normal(triangle))
              raise ReconstructionError,
                    "Normalized triangle #{triangle_index} is degenerate: #{triangle.inspect}"
            end

            signature = canonical_triangle_key(triangle)
            if signatures.key?(signature)
              raise ReconstructionError,
                    "Duplicate normalized triangle #{triangle_index}: #{triangle.inspect}"
            end
            signatures[signature] = triangle_index

            triangle.each { |vertex| vertices[vertex] = true }
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_incidence[edge] << triangle_index
            end
          end

          bad_edges = edge_incidence.select { |_edge, owners| owners.length != 2 }
          unless bad_edges.empty?
            sample = bad_edges.first(10).map do |edge, owners|
              { edge: edge, incidence: owners.length, triangles: owners }
            end
            raise TopologyChangedError,
                  "Normalized mesh is not a closed 2-manifold; " \
                  "bad_edges=#{bad_edges.length} sample=#{sample.inspect}"
          end

          adjacency = Array.new(triangles.length) { [] }
          edge_incidence.each_value do |owners|
            first, second = owners
            adjacency[first] << second
            adjacency[second] << first
          end
          component_count = graph_component_count(adjacency)
          unless component_count == 1
            raise TopologyChangedError,
                  "Normalized mesh has #{component_count} disconnected shell components"
          end

          {
            vertex_count: vertices.length,
            edge_count: edge_incidence.length,
            triangle_count: triangles.length,
            component_count: component_count,
            tested_triangle_pairs: 0
          }
        end

        def verify_triangle_rebuild!(expected_records, actual_records)
          expected = expected_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          actual = actual_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          return if expected == actual

          missing = expected - actual
          added = actual - expected
          raise ReconstructionError,
                "SketchUp changed the validated triangle complex during rebuild: " \
                "missing=#{missing.first(10).inspect} added=#{added.first(10).inspect}"
        end

        def graph_component_count(adjacency)
          visited = Array.new(adjacency.length, false)
          components = 0

          adjacency.each_index do |seed|
            next if visited[seed]

            components += 1
            visited[seed] = true
            queue = [seed]
            until queue.empty?
              current = queue.shift
              adjacency[current].each do |neighbor|
                next if visited[neighbor]

                visited[neighbor] = true
                queue << neighbor
              end
            end
          end

          components
        end

        def validate_triangle_intersections!(triangles)
          tested_pairs = 0

          triangles.each_with_index do |triangle_a, index_a|
            ((index_a + 1)...triangles.length).each do |index_b|
              triangle_b = triangles[index_b]
              next unless integer_aabbs_overlap?(triangle_a, triangle_b)

              tested_pairs += 1
              next if exact_triangle_intersection_allowed?(triangle_a, triangle_b)

              raise TopologyChangedError,
                    "Normalized triangles intersect outside their shared simplex: " \
                    "triangles=#{[index_a, index_b].inspect} " \
                    "a=#{triangle_a.inspect} b=#{triangle_b.inspect}"
            end
          end

          tested_pairs
        end

        def exact_triangle_intersection_allowed?(triangle_a, triangle_b)
          shared = triangle_a & triangle_b
          return false if shared.length == 3

          normal_a = integer_triangle_normal(triangle_a)
          normal_b = integer_triangle_normal(triangle_b)
          line_direction = integer_cross(normal_a, normal_b)

          if integer_zero_vector?(line_direction)
            return true unless integer_dot(
              normal_a,
              integer_subtract(triangle_b[0], triangle_a[0])
            ).zero?

            coplanar_triangle_intersection_allowed?(triangle_a, triangle_b, shared)
          else
            noncoplanar_triangle_intersection_allowed?(
              triangle_a,
              triangle_b,
              shared,
              normal_a,
              normal_b,
              line_direction
            )
          end
        end

        def noncoplanar_triangle_intersection_allowed?(
          triangle_a,
          triangle_b,
          shared,
          normal_a,
          normal_b,
          line_direction
        )
          interval_a = triangle_plane_parameter_interval(
            triangle_a,
            triangle_b[0],
            normal_b,
            line_direction
          )
          interval_b = triangle_plane_parameter_interval(
            triangle_b,
            triangle_a[0],
            normal_a,
            line_direction
          )
          return true unless interval_a && interval_b

          overlap_min = [interval_a[0], interval_b[0]].max
          overlap_max = [interval_a[1], interval_b[1]].min
          return true if overlap_min > overlap_max

          expected = shared.map { |point| integer_dot(line_direction, point) }.minmax
          return false if expected.nil?

          overlap_min == expected[0] && overlap_max == expected[1]
        end

        def triangle_plane_parameter_interval(triangle, plane_point, plane_normal, direction)
          signs = triangle.map do |point|
            integer_dot(plane_normal, integer_subtract(point, plane_point))
          end
          return nil if signs.all?(&:positive?) || signs.all?(&:negative?)

          parameters = []
          3.times do |index|
            point_a = triangle[index]
            point_b = triangle[(index + 1) % 3]
            sign_a = signs[index]
            sign_b = signs[(index + 1) % 3]

            parameters << Rational(integer_dot(direction, point_a), 1) if sign_a.zero?
            next unless (sign_a.positive? && sign_b.negative?) ||
                        (sign_a.negative? && sign_b.positive?)

            parameter = Rational(sign_a, sign_a - sign_b)
            value_a = integer_dot(direction, point_a)
            value_b = integer_dot(direction, point_b)
            parameters << (value_a + (parameter * (value_b - value_a)))
          end

          parameters.uniq.minmax unless parameters.empty?
        end
      end
    end
  end
end
