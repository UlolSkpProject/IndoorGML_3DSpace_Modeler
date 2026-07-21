# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        remove_const(:STRICT_COPLANAR_TOLERANCE_MM) if
          const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)
        STRICT_COPLANAR_TOLERANCE_MM = 0.00001

        private

        unless private_method_defined?(:repair_degenerate_source_triangles_before_runtime_regression_v2)
          alias_method :repair_degenerate_source_triangles_before_runtime_regression_v2,
                       :repair_degenerate_source_triangles
        end

        # A zero-area polygon emitted by SketchUp's source Face mesh has no
        # surface area to preserve. If the local diagonal repair cannot resolve
        # it, remove only the zero-area/duplicate records and force every affected
        # source Face through step-6 coplanar patch reconstruction.
        def repair_degenerate_source_triangles(
          triangle_records,
          coordinate_space: :grid
        )
          return repair_degenerate_source_triangles_before_runtime_regression_v2(
            triangle_records,
            coordinate_space: coordinate_space
          ) unless coordinate_space == :source

          repair_degenerate_source_triangles_before_runtime_regression_v2(
            triangle_records,
            coordinate_space: :source
          )
        rescue ReconstructionError => error
          degenerate_indices = triangle_records.each_index.select do |index|
            degenerate_triangle_record?(
              triangle_records[index],
              coordinate_space: :source
            )
          end
          forced_face_keys = source_face_keys_with_adjacent_triangles(
            triangle_records,
            degenerate_indices,
            coordinate_space: :source
          )
          sanitized, cleanup = sanitize_source_triangle_records(triangle_records)
          forced_face_keys.concat(cleanup[:affected_source_face_keys])
          forced_face_keys.compact!
          forced_face_keys.uniq!
          forced_lookup = forced_face_keys.to_h { |key| [key, true] }
          sanitized = sanitized.map do |record|
            if forced_lookup[record[:source_face_key]]
              record.merge(force_retriangulation: true)
            else
              record
            end
          end

          if sanitized.empty?
            raise ReconstructionError,
                  "Source triangle fallback removed every triangle: #{error.message}"
          end

          [
            sanitized,
            {
              repaired_triangles: 0,
              replaced_pairs: 0,
              deferred_to_patch_retriangulation: true,
              fallback_reason: "#{error.class}: #{error.message}",
              forced_source_face_keys: forced_face_keys,
              removed_source_degenerate_triangles:
                cleanup[:removed_degenerate_triangle_count],
              removed_source_duplicate_triangles:
                cleanup[:removed_duplicate_triangle_count]
            }
          ]
        end

        def sanitize_source_triangle_records(triangle_records)
          signatures = {}
          affected_source_face_keys = []
          removed_degenerate = 0
          removed_duplicate = 0

          records = triangle_records.filter_map do |record|
            if degenerate_triangle_record?(record, coordinate_space: :source)
              removed_degenerate += 1
              affected_source_face_keys << record[:source_face_key]
              next
            end

            signature = triangle_signature_for_space(record[:points], :source)
            if signatures.key?(signature)
              removed_duplicate += 1
              affected_source_face_keys << record[:source_face_key]
              affected_source_face_keys << signatures[signature][:source_face_key]
              next
            end

            signatures[signature] = record
            record
          end

          [
            records,
            {
              removed_degenerate_triangle_count: removed_degenerate,
              removed_duplicate_triangle_count: removed_duplicate,
              affected_source_face_keys: affected_source_face_keys.compact.uniq
            }
          ]
        end

        unless private_method_defined?(:normalize_triangle_records_allowing_collisions_before_runtime_regression_v2)
          alias_method :normalize_triangle_records_allowing_collisions_before_runtime_regression_v2,
                       :normalize_triangle_records_allowing_collisions
        end

        # Propagate source-space fallback markers into the report consumed by
        # collect_forced_retriangulation_keys.
        def normalize_triangle_records_allowing_collisions(
          triangle_records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          forced_face_keys = triangle_records.filter_map do |record|
            record[:source_face_key] if record[:force_retriangulation]
          end
          records, cleanup =
            normalize_triangle_records_allowing_collisions_before_runtime_regression_v2(
              triangle_records,
              axis_plane_plan,
              duplicate_diagnostics: duplicate_diagnostics
            )
          cleanup[:forced_source_face_keys] = (
            Array(cleanup[:forced_source_face_keys]) + forced_face_keys
          ).compact.uniq
          [records, cleanup]
        end

        # Surface equivalence is geometric, not metadata- or triangulation-based.
        # Triangles are clustered with the same strict tolerances used by the
        # post-rebuild coplanar cleanup. Shared edges are split at every collinear
        # vertex so T-junction/subdivided boundaries form one component.
        def normalized_surface_descriptor(triangle_records)
          records = triangle_records.reject do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            triangle.uniq.length != 3 ||
              integer_zero_vector?(integer_triangle_normal(triangle))
          end

          descriptors = []
          surface_coplanar_clusters(records).each do |plane_records|
            coplanar_geometry_components(plane_records).each do |component|
              edge_owners = split_triangle_edge_owners(component)
              overused = edge_owners.select { |_edge, owners| owners.length > 2 }
              unless overused.empty?
                raise TopologyChangedError,
                      "Surface descriptor found overused coplanar edges: " \
                      "#{overused.first(5).inspect}"
              end

              boundary_edges = edge_owners.filter_map do |edge, owners|
                edge if owners.length == 1
              end
              loops = exact_boundary_loops(boundary_edges).map do |loop|
                canonical_exact_loop(simplify_exact_loop(loop))
              end.sort
              descriptors << [surface_patch_plane_key(loops), loops]
            end
          end
          descriptors.sort
        end

        # SketchUp can merge coplanar triangles into one n-gon and then expose
        # a different internal triangulation through Face#mesh. A very thin
        # triangle from that triangulation has an unstable normal even when every
        # vertex lies on the original Face plane. For records emitted from the
        # same Face, use the widest triangle as the reference plane and let every
        # record whose vertices fit that plane inherit it.
        def surface_coplanar_clusters(records)
          clusters = []
          surface_records_with_reference_planes(records).each do |entry|
            record = entry[:record]
            plane = entry[:plane]
            cluster = clusters.find do |candidate|
              surface_planes_compatible?(candidate[:plane], plane)
            end
            if cluster
              cluster[:records] << record
            else
              clusters << { plane: plane, records: [record] }
            end
          end
          clusters.map { |entry| entry[:records] }
        end

        def surface_records_with_reference_planes(records)
          grouped_indices = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, index|
            face_key = record[:source_face_key]
            group_key = face_key.nil? ? [:record, index] : [:face, face_key]
            grouped_indices[group_key] << index
          end

          plane_by_index = {}
          tolerance_grid = STRICT_COPLANAR_TOLERANCE_MM / @tolerance_mm
          grouped_indices.each_value do |indices|
            reference_index = indices.max_by do |index|
              surface_triangle_area_measure(records[index])
            end
            reference_plane = surface_triangle_plane(records[reference_index])

            indices.each do |index|
              record = records[index]
              triangle = record[:points].map { |point| grid_indices(point) }
              plane_by_index[index] =
                if surface_plane_deviation_grid(reference_plane, triangle) <=
                   tolerance_grid
                  reference_plane
                else
                  surface_triangle_plane(record)
                end
            end
          end

          records.each_with_index.map do |record, index|
            { record: record, plane: plane_by_index.fetch(index) }
          end
        end

        def surface_triangle_area_measure(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          normal = integer_triangle_normal(triangle)
          integer_dot(normal, normal)
        end

        def surface_triangle_plane(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          normal = integer_triangle_normal(triangle).map(&:to_f)
          length = vector_length(normal)
          if length <= 0.0
            raise TopologyChangedError,
                  "Cannot build surface plane from degenerate triangle: #{triangle.inspect}"
          end

          unit = normal.map { |value| value / length }
          first_nonzero = unit.find { |value| value.abs > 1.0e-15 }
          if first_nonzero&.negative?
            unit = unit.map(&:-@)
          end
          {
            unit_normal: unit,
            offset: vector_dot(unit, triangle[0]),
            triangle: triangle
          }
        end

        def surface_planes_compatible?(first, second)
          dot = vector_dot(first[:unit_normal], second[:unit_normal]).abs
          threshold = Math.cos(
            STRICT_COPLANAR_ANGLE_TOLERANCE_DEG * Math::PI / 180.0
          )
          return false if dot + 1.0e-15 < threshold

          tolerance_grid = STRICT_COPLANAR_TOLERANCE_MM / @tolerance_mm
          surface_plane_deviation_grid(first, second[:triangle]) <= tolerance_grid &&
            surface_plane_deviation_grid(second, first[:triangle]) <= tolerance_grid
        end

        def surface_plane_deviation_grid(plane, triangle)
          triangle.map do |point|
            (vector_dot(plane[:unit_normal], point) - plane[:offset]).abs
          end.max || 0.0
        end

        def coplanar_geometry_components(records)
          edge_owners = split_triangle_edge_owners(records)
          adjacency = Array.new(records.length) { [] }
          edge_owners.each_value do |owners|
            owners.uniq.combination(2) do |first, second|
              adjacency[first] << second
              adjacency[second] << first
            end
          end

          visited = Array.new(records.length, false)
          records.each_index.filter_map do |seed|
            next if visited[seed]

            visited[seed] = true
            queue = [seed]
            component_indices = []
            until queue.empty?
              index = queue.shift
              component_indices << index
              adjacency[index].each do |neighbor|
                next if visited[neighbor]

                visited[neighbor] = true
                queue << neighbor
              end
            end
            component_indices.map { |index| records[index] }
          end
        end

        def split_triangle_edge_owners(records)
          points = records.flat_map do |record|
            record[:points].map { |point| grid_indices(point) }
          end.uniq
          edge_owners = Hash.new { |hash, key| hash[key] = [] }

          records.each_with_index do |record, record_index|
            triangle = record[:points].map { |point| grid_indices(point) }
            3.times do |edge_index|
              point_a = triangle[edge_index]
              point_b = triangle[(edge_index + 1) % 3]
              integer_points_on_segment_sorted(point_a, point_b, points)
                .each_cons(2) do |segment_start, segment_end|
                  next if segment_start == segment_end

                  edge = canonical_edge_key(segment_start, segment_end)
                  edge_owners[edge] << record_index unless
                    edge_owners[edge].include?(record_index)
                end
            end
          end
          edge_owners
        end

        def integer_points_on_segment_sorted(point_a, point_b, candidates)
          direction = integer_subtract(point_b, point_a)
          axis = direction.each_index.max_by { |index| direction[index].abs }
          denominator = direction[axis]
          return [point_a, point_b] if denominator.zero?

          candidates.select do |point|
            point == point_a || point == point_b ||
              integer_point_between?(point, point_a, point_b)
          end.sort_by do |point|
            Rational(point[axis] - point_a[axis], denominator)
          end.uniq
        end

        # Derive the canonical plane from a wide boundary triangle instead of
        # the first non-collinear triple. The latter can select a micro-sliver and
        # make the descriptor depend on SketchUp's internal n-gon diagonal.
        def surface_patch_plane_key(loops)
          points = loops.flatten(1).uniq.sort
          triangle = widest_surface_boundary_triangle(points)
          return exact_integer_plane_key(triangle) if triangle

          raise TopologyChangedError,
                "Surface patch boundary cannot define a plane: #{loops.inspect}"
        end

        def widest_surface_boundary_triangle(points)
          return nil if points.length < 3

          widest_pair = points.combination(2).max_by do |first, second|
            delta = integer_subtract(second, first)
            [integer_dot(delta, delta), first, second]
          end
          return nil unless widest_pair

          first, second = widest_pair
          third = points.reject { |point| point == first || point == second }
                        .max_by do |point|
            triangle = [first, second, point]
            normal = integer_triangle_normal(triangle)
            [integer_dot(normal, normal), point]
          end
          return nil unless third

          triangle = [first, second, third]
          return nil if integer_zero_vector?(integer_triangle_normal(triangle))

          triangle
        end
      end
    end
  end
end
