# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # Returns true when an exact coplanar patch must be rebuilt instead of
        # preserving its current triangulation.
        def exact_coplanar_patch_retriangulation_required?(patch)
          triangles = patch.map do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            source_normal = Array(record[:source_normal]).map(&:to_f)
            actual_normal = integer_triangle_normal(triangle)
            return true if source_normal.length == 3 &&
                           vector_dot(actual_normal, source_normal).negative?
            return true if exact_triangle_minimum_altitude_mm(triangle) < @tolerance_mm

            triangle
          end

          validate_triangle_intersections!(triangles)
          false
        rescue TopologyChangedError
          true
        end

        def exact_triangle_minimum_altitude_mm(triangle)
          normal_length = Math.sqrt(
            integer_dot(
              integer_triangle_normal(triangle),
              integer_triangle_normal(triangle)
            ).to_f
          )
          longest_edge = 3.times.map do |index|
            edge = integer_subtract(
              triangle[index],
              triangle[(index + 1) % 3]
            )
            Math.sqrt(integer_dot(edge, edge).to_f)
          end.max
          return 0.0 unless longest_edge&.positive?

          (normal_length / longest_edge) * @tolerance_mm
        end

        def exact_coplanar_triangle_patches(triangle_records)
          grouped = triangle_records.group_by do |record|
            exact_coplanar_patch_key(record)
          end
          patches = []

          grouped.each_value do |records|
            edge_owners = Hash.new { |hash, key| hash[key] = [] }
            records.each_with_index do |record, index|
              triangle = record[:points].map { |point| grid_indices(point) }
              3.times do |edge_index|
                edge = canonical_edge_key(
                  triangle[edge_index],
                  triangle[(edge_index + 1) % 3]
                )
                edge_owners[edge] << index
              end
            end

            adjacency = Array.new(records.length) { [] }
            edge_owners.each_value do |owners|
              next unless owners.length == 2

              first, second = owners
              adjacency[first] << second
              adjacency[second] << first
            end

            visited = Array.new(records.length, false)
            records.each_index do |seed|
              next if visited[seed]

              visited[seed] = true
              queue = [seed]
              component = []
              until queue.empty?
                index = queue.shift
                component << records[index]
                adjacency[index].each do |neighbor|
                  next if visited[neighbor]

                  visited[neighbor] = true
                  queue << neighbor
                end
              end
              patches << component
            end
          end

          patches
        end

        def exact_coplanar_patch_key(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          plane_key = exact_integer_plane_key(triangle)
          normal = plane_key.first(3)
          source_normal = Array(record[:source_normal]).map(&:to_f)
          orientation = if source_normal.length == 3 &&
                           vector_dot(normal, source_normal).negative?
                          -1
                        else
                          1
                        end

          [
            plane_key,
            orientation,
            metadata_identity(record[:material]),
            metadata_identity(record[:back_material]),
            metadata_identity(record[:layer])
          ]
        end

        def metadata_identity(value)
          return nil if value.nil?
          return [:persistent_id, value.persistent_id] if value.respond_to?(:persistent_id)

          [:object_id, value.object_id]
        rescue StandardError
          [:object_id, value.object_id]
        end

        def exact_integer_plane_key(triangle)
          normal = integer_triangle_normal(triangle)
          if integer_zero_vector?(normal)
            raise ReconstructionError,
                  "Cannot form an exact plane from a zero-area triangle: #{triangle.inspect}"
          end

          divisor = normal.map(&:abs).reject(&:zero?).reduce { |gcd, value| gcd.gcd(value) }
          primitive = normal.map { |value| value / divisor }
          first_nonzero = primitive.find { |value| !value.zero? }
          primitive = primitive.map(&:-@) if first_nonzero.negative?
          primitive + [integer_dot(primitive, triangle[0])]
        end

        def retriangulate_exact_coplanar_patch(patch)
          point_by_key = {}
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          patch.each_with_index do |record, index|
            triangle = record[:points].map do |point|
              key = grid_indices(point)
              point_by_key[key] ||= point
              key
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_owners[edge] << index
            end
          end

          overused = edge_owners.select { |_edge, owners| owners.length > 2 }
          unless overused.empty?
            raise TopologyChangedError,
                  "Exact coplanar patch has overused edges: #{overused.first(10).inspect}"
          end

          boundary_edges = edge_owners.filter_map do |edge, owners|
            edge if owners.length == 1
          end
          if boundary_edges.empty?
            raise TopologyChangedError, 'Exact coplanar patch has no preserved boundary'
          end

          loops = exact_boundary_loops(boundary_edges)
          plane_key = exact_integer_plane_key(
            patch.first[:points].map { |point| grid_indices(point) }
          )
          drop_axis = plane_key.first(3).each_index.max_by do |axis|
            plane_key[axis].abs
          end
          outer, holes = classify_exact_patch_loops(loops, drop_axis)
          expected_area2 = integer_polygon_area2(
            outer.map { |point| integer_project_2d(point, drop_axis) }
          ).abs - holes.sum do |hole|
            integer_polygon_area2(
              hole.map { |point| integer_project_2d(point, drop_axis) }
            ).abs
          end
          triangle_keys = triangulate_exact_polygon_with_holes(
            outer,
            holes,
            drop_axis
          )

          template = patch.first
          replacements = triangle_keys.each_with_index.map do |keys, index|
            points = keys.map { |key| point_by_key.fetch(key) }
            points = orient_patch_triangle(points, template[:source_normal])
            template.merge(
              points: points,
              source_polygon_index: index
            )
          end

          validate_exact_patch_replacement!(
            replacements,
            boundary_edges,
            loops.length,
            drop_axis,
            expected_area2
          )

          [
            replacements,
            {
              boundary_loops: loops.length,
              holes: holes.length
            }
          ]
        end

        def exact_boundary_loops(boundary_edges)
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          boundary_edges.each do |point_a, point_b|
            adjacency[point_a] << point_b
            adjacency[point_b] << point_a
          end
          bad_vertices = adjacency.select { |_point, neighbors| neighbors.uniq.length != 2 }
          unless bad_vertices.empty?
            raise TopologyChangedError,
                  "Exact coplanar patch boundary is branched: " \
                  "#{bad_vertices.first(10).inspect}"
          end

          unused = boundary_edges.each_with_object({}) do |edge, result|
            result[canonical_edge_key(edge[0], edge[1])] = true
          end
          loops = []
          until unused.empty?
            seed = unused.keys.first
            start_point, current = seed
            previous = start_point
            loop_points = [start_point]
            unused.delete(seed)

            boundary_edges.length.times do
              loop_points << current
              break if current == start_point

              following = adjacency.fetch(current).find do |candidate|
                candidate != previous &&
                  unused.key?(canonical_edge_key(current, candidate))
              end
              following ||= adjacency.fetch(current).find do |candidate|
                unused.key?(canonical_edge_key(current, candidate))
              end
              unless following
                raise TopologyChangedError,
                      "Exact coplanar patch boundary does not form a closed loop at " \
                      "#{current.inspect}"
              end

              unused.delete(canonical_edge_key(current, following))
              previous, current = current, following
            end

            unless loop_points.last == start_point
              raise TopologyChangedError, 'Exact coplanar patch boundary walk did not close'
            end
            loop_points.pop
            if loop_points.length < 3
              raise TopologyChangedError,
                    "Exact coplanar patch has a boundary loop with fewer than three vertices"
            end
            loops << loop_points
          end

          loops
        end

        def classify_exact_patch_loops(loops, drop_axis)
          projected = loops.map do |loop|
            [loop, loop.map { |point| integer_project_2d(point, drop_axis) }]
          end
          projected.each do |_loop, polygon|
            if integer_polygon_area2(polygon).zero?
              raise TopologyChangedError, 'Exact coplanar patch has a zero-area boundary loop'
            end
            unless simple_integer_polygon_2d?(polygon)
              raise TopologyChangedError,
                    'Exact coplanar patch boundary self-intersects after normalization'
            end
          end

          outer_entry = projected.max_by do |_loop, polygon|
            integer_polygon_area2(polygon).abs
          end
          outer_loop, outer_polygon = outer_entry
          holes = projected.reject { |entry| entry.equal?(outer_entry) }
          holes.each do |_loop, polygon|
            unless integer_point_in_polygon_2d?(polygon.first, outer_polygon)
              raise TopologyChangedError,
                    'Exact coplanar patch contains more than one exterior boundary'
            end
          end

          outer_loop = outer_loop.reverse if integer_polygon_area2(outer_polygon).negative?
          oriented_holes = holes.map do |loop, polygon|
            integer_polygon_area2(polygon).positive? ? loop.reverse : loop
          end
          [outer_loop, oriented_holes]
        end
      end
    end
  end
end
