# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        unless private_method_defined?(
          :retriangulate_exact_coplanar_patches_before_folded_sliver_strip_v2
        )
          alias_method(
            :retriangulate_exact_coplanar_patches_before_folded_sliver_strip_v2,
            :retriangulate_exact_coplanar_patches
          )
        end

        # Grid snapping can turn several source-mesh triangles that were
        # effectively collinear on a source Face boundary into a microscopic
        # bow-tie strip on a foreign exact plane. The strip itself has no
        # meaningful source surface: every triangle is thinner than the grid
        # tolerance and its normal is nearly perpendicular to the source Face
        # normal.
        #
        # Repair is deliberately conservative:
        # - one source Face only
        # - one self-intersecting boundary loop
        # - every patch triangle is a grid sliver
        # - every patch boundary edge has exactly two global owners
        # - the longest boundary edge has one non-patch owner from the same Face
        # - the alternate boundary chain is monotonic and stays within one grid
        #   tolerance of that longest edge
        #
        # The zero-area strip is removed and the same-Face owner triangle on the
        # longest chord is fanned across the preserved alternate boundary chain.
        # This keeps every neighboring shell edge exactly two-owned without
        # accepting a general self-intersecting polygon.
        def retriangulate_exact_coplanar_patches(
          triangle_records,
          forced_source_face_keys: [],
          force_all: false
        )
          repaired_records, folded_report =
            repair_folded_sliver_strips(triangle_records)

          rebuilt_records, report =
            retriangulate_exact_coplanar_patches_before_folded_sliver_strip_v2(
              repaired_records,
              forced_source_face_keys: forced_source_face_keys,
              force_all: force_all
            )

          report = report.merge(folded_report)
          [rebuilt_records, report]
        end

        def repair_folded_sliver_strips(triangle_records)
          records = triangle_records.dup
          repairs = []
          iteration_limit = [records.length, 1].max
          iterations = 0

          loop do
            plan = folded_sliver_strip_repair_plan(records)
            break unless plan

            records = apply_folded_sliver_strip_repair(records, plan)
            repairs << plan[:report]
            iterations += 1
            if iterations > iteration_limit
              raise ReconstructionError,
                    'Folded sliver strip repair exceeded its iteration limit'
            end
          end

          [
            records,
            {
              folded_sliver_strip_repairs: repairs.length,
              folded_sliver_removed_triangles:
                repairs.sum { |entry| entry[:removed_patch_triangles] },
              folded_sliver_replacement_triangles:
                repairs.sum { |entry| entry[:replacement_triangles] },
              folded_sliver_source_face_keys:
                repairs.flat_map { |entry| entry[:source_face_keys] }.uniq,
              folded_sliver_max_boundary_deviation_mm:
                repairs.map { |entry| entry[:max_boundary_deviation_mm] }.max || 0.0,
              folded_sliver_repairs: repairs
            }
          ]
        end

        def folded_sliver_strip_repair_plan(records)
          patches = exact_coplanar_triangle_patches(records)
          global_edge_owners = exact_record_edge_owners(records)

          patches.each do |patch|
            plan = folded_sliver_patch_plan(
              records,
              patch,
              global_edge_owners
            )
            return plan if plan
          end

          nil
        end

        def folded_sliver_patch_plan(records, patch, global_edge_owners)
          return nil if patch.length < 2
          return nil unless patch.all? do |record|
            grid_triangle_sliver?(record[:points])
          end

          source_keys = patch.filter_map { |record| record[:source_face_key] }.uniq
          return nil unless source_keys.length == 1

          patch_lookup = patch.to_h { |record| [record.object_id, true] }
          point_by_key = {}
          local_edge_owners = Hash.new { |hash, key| hash[key] = [] }

          patch.each_with_index do |record, record_index|
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
              local_edge_owners[edge] << record_index
            end
          end

          return nil if local_edge_owners.any? do |_edge, owners|
            owners.length > 2
          end

          boundary_edges = local_edge_owners.filter_map do |edge, owners|
            edge if owners.length == 1
          end
          return nil if boundary_edges.length < 3
          return nil unless boundary_edges.all? do |edge|
            Array(global_edge_owners[edge]).length == 2
          end

          loops = exact_boundary_loops(boundary_edges)
          return nil unless loops.length == 1

          loop_points = loops.first
          plane_key = exact_integer_plane_key(
            patch.first[:points].map { |point| grid_indices(point) }
          )
          drop_axis = plane_key.first(3).each_index.max_by do |axis|
            plane_key[axis].abs
          end
          polygon = loop_points.map do |point|
            integer_project_2d(point, drop_axis)
          end
          return nil if simple_integer_polygon_2d?(polygon)

          source_normal = Array(patch.first[:source_normal]).map(&:to_f)
          return nil unless source_normal.length == 3

          patch_normal = plane_key.first(3).map(&:to_f)
          source_length = vector_length(source_normal)
          patch_length = vector_length(patch_normal)
          return nil unless source_length.positive? && patch_length.positive?

          normal_alignment =
            vector_dot(source_normal, patch_normal).abs /
            (source_length * patch_length)
          return nil unless normal_alignment <= 0.1

          chord = boundary_edges.max_by do |first, second|
            delta = integer_subtract(second, first)
            integer_dot(delta, delta)
          end
          return nil unless chord

          chain = exact_loop_path_excluding_edge(loop_points, chord)
          return nil unless chain && chain.length > 2

          chain_metrics = folded_sliver_chain_metrics(chain, chord)
          return nil unless chain_metrics
          return nil if chain_metrics[:max_deviation_mm] > @tolerance_mm

          chord_owners = Array(global_edge_owners[chord])
          host_indices = chord_owners.reject do |record_index|
            patch_lookup[records[record_index].object_id]
          end
          return nil unless host_indices.length == 1

          host_index = host_indices.first
          host_record = records[host_index]
          return nil unless host_record[:source_face_key] == source_keys.first

          host_triangle = host_record[:points].map { |point| grid_indices(point) }
          return nil unless host_triangle.include?(chord[0]) &&
                            host_triangle.include?(chord[1])

          host_third_key = (host_triangle - chord).first
          return nil unless host_third_key

          records.each do |record|
            Array(record[:points]).each do |point|
              point_by_key[grid_indices(point)] ||= point
            end
          end
          return nil unless chain.all? { |key| point_by_key.key?(key) }
          return nil unless point_by_key.key?(host_third_key)

          patch_indices = records.each_index.select do |index|
            patch_lookup[records[index].object_id]
          end

          replacements = chain.each_cons(2).map do |first_key, second_key|
            points = [
              point_by_key.fetch(first_key),
              point_by_key.fetch(host_third_key),
              point_by_key.fetch(second_key)
            ]
            points = orient_folded_sliver_triangle(
              points,
              host_record[:source_normal]
            )
            host_record.merge(points: points)
          end

          return nil if replacements.empty?
          return nil if replacements.any? do |record|
            triangle = record[:points].map { |point| grid_indices(point) }
            triangle.uniq.length != 3 ||
              integer_zero_vector?(integer_triangle_normal(triangle))
          end

          {
            patch_indices: patch_indices,
            host_index: host_index,
            replacements: replacements,
            report: {
              source_face_keys: source_keys,
              removed_patch_triangles: patch.length,
              replacement_triangles: replacements.length,
              chord: chord,
              chain: chain,
              max_boundary_deviation_mm:
                chain_metrics[:max_deviation_mm],
              patch_source_normal_alignment: normal_alignment
            }
          }
        rescue TopologyChangedError, ReconstructionError
          nil
        end

        def exact_record_edge_owners(records)
          owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, record_index|
            triangle = record[:points].map { |point| grid_indices(point) }
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              owners[edge] << record_index
            end
          end
          owners
        end

        def exact_loop_path_excluding_edge(loop_points, edge)
          first_index = loop_points.index(edge[0])
          second_index = loop_points.index(edge[1])
          return nil unless first_index && second_index

          count = loop_points.length
          return nil unless (first_index - second_index).abs == 1 ||
                            [first_index, second_index].sort == [0, count - 1]

          direct_forward = ((first_index + 1) % count) == second_index
          start_index = direct_forward ? second_index : first_index
          end_point = direct_forward ? edge[0] : edge[1]

          path = [loop_points[start_index]]
          index = start_index
          count.times do
            index = (index + 1) % count
            path << loop_points[index]
            break if loop_points[index] == end_point
          end

          return nil unless path.last == end_point
          path
        end

        def folded_sliver_chain_metrics(chain, chord)
          start_point = chord[0]
          end_point = chord[1]
          direction = integer_subtract(end_point, start_point)
          denominator = integer_dot(direction, direction)
          return nil unless denominator.positive?

          ordered_chain =
            if chain.first == start_point && chain.last == end_point
              chain
            elsif chain.first == end_point && chain.last == start_point
              chain.reverse
            else
              return nil
            end

          parameters = ordered_chain.map do |point|
            offset = integer_subtract(point, start_point)
            Rational(integer_dot(offset, direction), denominator)
          end
          return nil unless parameters.first == 0 && parameters.last == 1
          return nil unless parameters.each_cons(2).all? do |first, second|
            first < second
          end
          return nil unless parameters.all? { |value| value.between?(0, 1) }

          direction_length = Math.sqrt(denominator.to_f)
          max_deviation_grid = ordered_chain.map do |point|
            offset = integer_subtract(point, start_point)
            cross = integer_cross(direction, offset)
            Math.sqrt(integer_dot(cross, cross).to_f) / direction_length
          end.max || 0.0

          {
            chain: ordered_chain,
            max_deviation_mm: max_deviation_grid * @tolerance_mm
          }
        end

        def orient_folded_sliver_triangle(points, source_normal)
          normal = integer_triangle_normal(
            points.map { |point| grid_indices(point) }
          )
          source = Array(source_normal).map(&:to_f)
          return points unless source.length == 3
          return points unless vector_dot(normal.map(&:to_f), source).negative?

          [points[0], points[2], points[1]]
        end

        def apply_folded_sliver_strip_repair(records, plan)
          removed_lookup =
            (plan[:patch_indices] + [plan[:host_index]])
              .to_h { |index| [index, true] }

          repaired = []
          records.each_with_index do |record, index|
            if index == plan[:host_index]
              repaired.concat(plan[:replacements])
              next
            end
            next if removed_lookup[index]

            repaired << record
          end
          repaired
        end
      end
    end
  end
end
