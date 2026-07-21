# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        FINAL_BOUNDARY_REPAIR_MAX_DISTANCE_GRID = 1.0 unless const_defined?(:FINAL_BOUNDARY_REPAIR_MAX_DISTANCE_GRID, false)
        FINAL_BOUNDARY_REPAIR_MAX_INTERNAL_VERTICES = 16 unless const_defined?(:FINAL_BOUNDARY_REPAIR_MAX_INTERNAL_VERTICES, false)
        FINAL_BOUNDARY_REPAIR_MAX_NORMAL_DEVIATION_DEG = 1.0 unless const_defined?(:FINAL_BOUNDARY_REPAIR_MAX_NORMAL_DEVIATION_DEG, false)
        FINAL_BOUNDARY_REPAIR_MAX_RELATIVE_STRIP_AREA = 0.01 unless const_defined?(:FINAL_BOUNDARY_REPAIR_MAX_RELATIVE_STRIP_AREA, false)
        FINAL_BOUNDARY_REPAIR_MAX_PASSES = 100 unless const_defined?(:FINAL_BOUNDARY_REPAIR_MAX_PASSES, false)

        private

        unless private_method_defined?(:retriangulate_exact_coplanar_patches_before_final_boundary_v2)
          alias_method(
            :retriangulate_exact_coplanar_patches_before_final_boundary_v2,
            :retriangulate_exact_coplanar_patches
          )
        end

        def retriangulate_exact_coplanar_patches(
          triangle_records,
          forced_source_face_keys: [],
          force_all: false
        )
          rebuilt, report = retriangulate_exact_coplanar_patches_before_final_boundary_v2(
            triangle_records,
            forced_source_face_keys: forced_source_face_keys,
            force_all: force_all
          )
          rebuilt, before_cleanup = sanitize_triangle_records(rebuilt)
          rebuilt, boundary_repair = repair_final_boundary_conformity(rebuilt)
          rebuilt, after_cleanup = sanitize_triangle_records(rebuilt)

          [
            rebuilt,
            report.merge(
              final_boundary_conformity_repair: boundary_repair,
              final_boundary_pre_repair_cleanup: before_cleanup,
              final_boundary_post_repair_cleanup: after_cleanup
            )
          ]
        end

        # Repairs a final incidence-1 cycle only when it contains one unique long
        # chord and one monotone near-chord chain. Chain vertices stay on the grid;
        # the chord-owner triangle is replaced by a bounded fan.
        def repair_final_boundary_conformity(records)
          working = records.map(&:dup)
          repairs = []
          repaired_owner_signatures = {}

          FINAL_BOUNDARY_REPAIR_MAX_PASSES.times do
            inventory = final_boundary_inventory(working)
            overused = inventory[:owners].select { |_edge, owners| owners.length > 2 }
            unless overused.empty?
              raise TopologyChangedError,
                    "Final boundary repair refuses overused edges: #{overused.first(10).inspect}"
            end

            boundary = inventory[:owners].filter_map { |edge, owners| edge if owners.length == 1 }
            break if boundary.empty?

            analyses = final_boundary_components(boundary).map do |component|
              final_boundary_component_analysis(component, inventory, working)
            end
            rejected = analyses.find { |entry| %i[ambiguous unsafe].include?(entry[:status]) }
            if rejected
              raise TopologyChangedError,
                    "Final boundary repair #{rejected[:status]} component: " \
                    "#{final_boundary_diagnostic(rejected).inspect}"
            end

            analysis = analyses.select { |entry| entry[:status] == :repairable }.min_by do |entry|
              candidate = entry[:candidate]
              [-candidate[:chord_length_mm], candidate[:chord]]
            end
            break unless analysis

            candidate = analysis[:candidate]
            owner_signature = canonical_triangle_key(
              inventory[:triangles][candidate[:owner_index]]
            )
            if repaired_owner_signatures[owner_signature]
              raise TopologyChangedError,
                    "Final boundary repair would modify one owner twice: #{owner_signature.inspect}"
            end

            working, repair = final_boundary_apply_candidate(working, inventory, candidate)
            repaired_owner_signatures[owner_signature] = true
            repairs << repair
          end

          inventory = final_boundary_inventory(working)
          remaining = inventory[:owners].count { |_edge, owners| owners.length == 1 }
          [
            working,
            {
              repair_policy: :adopt_existing_boundary_chain,
              repaired_component_count: repairs.length,
              replaced_triangle_count: repairs.sum { |entry| entry[:replacement_triangle_count] },
              inserted_chain_vertex_count: repairs.sum { |entry| entry[:internal_vertex_count] },
              max_chain_distance_mm: repairs.map { |entry| entry[:max_chain_distance_mm] }.max || 0.0,
              total_surface_strip_area_mm2: repairs.sum { |entry| entry[:surface_strip_area_mm2] },
              max_surface_strip_area_mm2: repairs.map { |entry| entry[:surface_strip_area_mm2] }.max || 0.0,
              max_owner_plane_distance_mm: repairs.map { |entry| entry[:max_owner_plane_distance_mm] }.max || 0.0,
              max_normal_deviation_deg: repairs.map { |entry| entry[:max_normal_deviation_deg] }.max || 0.0,
              remaining_boundary_edge_count: remaining,
              repairs: repairs
            }
          ]
        end

        def final_boundary_inventory(records)
          triangles = []
          points = {}
          owners = Hash.new { |hash, key| hash[key] = [] }
          records.each_with_index do |record, triangle_index|
            triangle = record[:points].map do |point|
              key = grid_indices(point)
              points[key] ||= point
              key
            end
            triangles << triangle
            3.times do |index|
              edge = canonical_edge_key(triangle[index], triangle[(index + 1) % 3])
              owners[edge] << triangle_index
            end
          end
          { triangles: triangles, points: points, owners: owners }
        end

        def final_boundary_components(edges)
          by_vertex = Hash.new { |hash, key| hash[key] = [] }
          edges.each do |edge|
            by_vertex[edge[0]] << edge
            by_vertex[edge[1]] << edge
          end
          unused = edges.to_h { |edge| [edge, true] }
          components = []
          until unused.empty?
            queue = [unused.keys.first]
            unused.delete(queue.first)
            component = []
            until queue.empty?
              edge = queue.shift
              component << edge
              edge.each do |vertex|
                by_vertex[vertex].each { |neighbor| queue << neighbor if unused.delete(neighbor) }
              end
            end
            components << component.sort
          end
          components
        end

        def final_boundary_component_analysis(component, inventory, records)
          degree = Hash.new(0)
          component.each { |edge| edge.each { |vertex| degree[vertex] += 1 } }
          return { status: :none, reason: :not_simple_cycle, component: component } unless
            degree.values.all? { |value| value == 2 }

          candidates = component.filter_map do |chord|
            final_boundary_candidate(chord, component, inventory, records)
          end
          return { status: :none, reason: :no_chord_chain, component: component } if candidates.empty?
          return {
            status: :ambiguous,
            reason: :multiple_chords,
            component: component,
            candidates: candidates
          } if candidates.length > 1

          candidate = candidates.first
          issue = final_boundary_safety_issue(candidate)
          return {
            status: :unsafe,
            reason: issue,
            component: component,
            candidate: candidate
          } if issue

          { status: :repairable, component: component, candidate: candidate }
        end

        def final_boundary_candidate(chord, component, inventory, records)
          path = final_boundary_path(component, chord)
          return nil unless path && path.length >= 3

          internal = path[1...-1]
          return nil if internal.empty? || internal.length > FINAL_BOUNDARY_REPAIR_MAX_INTERNAL_VERTICES

          direction = integer_subtract(path.last, path.first)
          length_squared = integer_dot(direction, direction)
          return nil unless length_squared.positive?

          parameters = []
          distances = []
          previous = Rational(0, 1)
          internal.each do |point|
            offset = integer_subtract(point, path.first)
            parameter = Rational(integer_dot(offset, direction), length_squared)
            return nil unless parameter > previous && parameter < 1

            cross = integer_cross(direction, offset)
            distance = Math.sqrt(integer_dot(cross, cross).to_f / length_squared)
            return nil if distance > FINAL_BOUNDARY_REPAIR_MAX_DISTANCE_GRID + 1.0e-12

            parameters << parameter.to_f
            distances << distance
            previous = parameter
          end

          chord_owners = inventory[:owners][chord]
          return nil unless chord_owners.length == 1

          chain_edges = path.each_cons(2).map { |a, b| canonical_edge_key(a, b) }
          return nil unless chain_edges.sort == (component - [chord]).sort

          chain_owner_indices = chain_edges.map do |edge|
            edge_owners = inventory[:owners][edge]
            return nil unless edge_owners.length == 1

            edge_owners.first
          end
          owner_index = chord_owners.first
          return nil if chain_owner_indices.include?(owner_index)

          owner_triangle = inventory[:triangles][owner_index]
          owner_edge_index = 3.times.find do |index|
            canonical_edge_key(owner_triangle[index], owner_triangle[(index + 1) % 3]) == chord
          end
          return nil unless owner_edge_index

          start_point = owner_triangle[owner_edge_index]
          end_point = owner_triangle[(owner_edge_index + 1) % 3]
          path = path.reverse if path.first == end_point && path.last == start_point
          return nil unless path.first == start_point && path.last == end_point

          opposite = owner_triangle[(owner_edge_index + 2) % 3]
          normal = integer_triangle_normal(owner_triangle)
          return nil if integer_zero_vector?(normal)

          chord_grid = Math.sqrt(length_squared.to_f)
          chain_grid = path.each_cons(2).sum do |a, b|
            vector = integer_subtract(b, a)
            Math.sqrt(integer_dot(vector, vector).to_f)
          end
          strip_grid2 = path.each_cons(2).sum do |a, b|
            va = integer_subtract(a, path.first)
            vb = integer_subtract(b, path.first)
            cross = integer_cross(va, vb)
            0.5 * Math.sqrt(integer_dot(cross, cross).to_f)
          end
          normal_length = Math.sqrt(integer_dot(normal, normal).to_f)
          plane_distances = internal.map do |point|
            offset = integer_subtract(point, owner_triangle[0])
            integer_dot(normal, offset).abs.to_f / normal_length * @tolerance_mm
          end
          owner_record = records[owner_index]

          {
            chord: chord,
            component: component,
            path: path,
            internal: internal,
            parameters: parameters,
            max_chain_distance_mm: (distances.max || 0.0) * @tolerance_mm,
            chord_length_mm: chord_grid * @tolerance_mm,
            chain_length_mm: chain_grid * @tolerance_mm,
            chain_excess_mm: (chain_grid - chord_grid) * @tolerance_mm,
            surface_strip_area_mm2: strip_grid2 * (@tolerance_mm**2),
            original_area_mm2: 0.5 * normal_length * (@tolerance_mm**2),
            max_owner_plane_distance_mm: plane_distances.max || 0.0,
            owner_index: owner_index,
            owner_triangle: owner_triangle,
            opposite: opposite,
            normal: normal,
            chain_owner_indices: chain_owner_indices,
            source_face_key: owner_record[:source_face_key],
            source_polygon_index: owner_record[:source_polygon_index],
            chain_owner_provenance: chain_owner_indices.map do |index|
              record = records[index]
              {
                triangle_index: index,
                source_face_key: record[:source_face_key],
                source_polygon_index: record[:source_polygon_index]
              }
            end
          }
        end

        def final_boundary_path(component, removed)
          adjacency = Hash.new { |hash, key| hash[key] = [] }
          component.each do |edge|
            next if edge == removed

            adjacency[edge[0]] << edge[1]
            adjacency[edge[1]] << edge[0]
          end
          start_point, end_point = removed
          return nil unless adjacency[start_point].length == 1 && adjacency[end_point].length == 1

          path = [start_point]
          previous = nil
          current = start_point
          component.length.times do
            break if current == end_point

            following = adjacency[current].reject { |point| point == previous }
            return nil unless following.length == 1
            return nil if path.include?(following.first) && following.first != end_point

            path << following.first
            previous, current = current, following.first
          end
          path.last == end_point && path.length == component.length ? path : nil
        end

        def final_boundary_safety_issue(candidate)
          tolerance = @tolerance_mm + GRID_EPSILON_MM
          return :chain_too_far if candidate[:max_chain_distance_mm] > tolerance

          maximum_excess = @tolerance_mm * [candidate[:internal].length, 1].max
          return :chain_too_long if candidate[:chain_excess_mm] > maximum_excess + GRID_EPSILON_MM

          chord_area_limit = candidate[:chord_length_mm] * @tolerance_mm
          return :strip_area_chord_limit if
            candidate[:surface_strip_area_mm2] > chord_area_limit + GRID_EPSILON_MM**2

          relative_limit = candidate[:original_area_mm2] * FINAL_BOUNDARY_REPAIR_MAX_RELATIVE_STRIP_AREA
          return :strip_area_relative_limit if
            candidate[:surface_strip_area_mm2] > relative_limit + GRID_EPSILON_MM**2

          return :owner_plane_distance if candidate[:max_owner_plane_distance_mm] > tolerance

          nil
        end

        def final_boundary_apply_candidate(records, inventory, candidate)
          owner_index = candidate[:owner_index]
          owner_record = records[owner_index]
          original_normal = candidate[:normal]
          original_length = Math.sqrt(integer_dot(original_normal, original_normal).to_f)
          max_deviation = 0.0

          replacements = candidate[:path].each_cons(2).map.with_index do |(a, b), index|
            triangle = [a, b, candidate[:opposite]]
            normal = integer_triangle_normal(triangle)
            raise TopologyChangedError, "Final boundary repair creates zero area: #{triangle.inspect}" if
              integer_zero_vector?(normal)

            dot = integer_dot(normal, original_normal)
            raise TopologyChangedError, "Final boundary repair reverses triangle: #{triangle.inspect}" unless
              dot.positive?

            normal_length = Math.sqrt(integer_dot(normal, normal).to_f)
            cosine = [[dot.to_f / (normal_length * original_length), -1.0].max, 1.0].min
            deviation = Math.acos(cosine) * 180.0 / Math::PI
            if deviation > FINAL_BOUNDARY_REPAIR_MAX_NORMAL_DEVIATION_DEG
              raise TopologyChangedError,
                    "Final boundary repair normal deviation #{deviation} exceeds " \
                    "#{FINAL_BOUNDARY_REPAIR_MAX_NORMAL_DEVIATION_DEG} degrees"
            end
            max_deviation = [max_deviation, deviation].max

            points = triangle.map { |key| inventory[:points][key] || point_from_grid_indices(key) }
            owner_record.merge(points: points, final_boundary_repair_segment_index: index)
          end

          signatures = records.each_with_index.each_with_object({}) do |(record, index), result|
            next if index == owner_index

            key = canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
            result[key] = true
          end
          replacements.each do |record|
            key = canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
            raise TopologyChangedError, "Final boundary repair duplicates triangle: #{key.inspect}" if signatures[key]

            signatures[key] = true
          end

          trial = records[0...owner_index] + replacements + Array(records[(owner_index + 1)..])
          before = inventory[:owners].filter_map { |edge, owners| edge if owners.length == 1 }.sort
          after_inventory = final_boundary_inventory(trial)
          overused = after_inventory[:owners].select { |_edge, owners| owners.length > 2 }
          raise TopologyChangedError, "Final boundary repair overuses edges: #{overused.inspect}" unless overused.empty?

          after = after_inventory[:owners].filter_map { |edge, owners| edge if owners.length == 1 }.sort
          expected = (before - candidate[:component]).sort
          unless after == expected
            raise TopologyChangedError,
                  "Final boundary repair changed unexpected boundary edges: " \
                  "expected=#{expected.first(20).inspect} actual=#{after.first(20).inspect}"
          end

          [
            trial,
            {
              chord: candidate[:chord],
              chain: candidate[:path],
              owner_triangle_index: owner_index,
              owner_triangle_points: candidate[:owner_triangle],
              source_face_key: candidate[:source_face_key],
              source_polygon_index: candidate[:source_polygon_index],
              chain_owner_provenance: candidate[:chain_owner_provenance],
              internal_vertex_count: candidate[:internal].length,
              replacement_triangle_count: replacements.length,
              chain_parameters: candidate[:parameters],
              max_chain_distance_mm: candidate[:max_chain_distance_mm],
              chord_length_mm: candidate[:chord_length_mm],
              chain_length_mm: candidate[:chain_length_mm],
              chain_excess_mm: candidate[:chain_excess_mm],
              surface_strip_area_mm2: candidate[:surface_strip_area_mm2],
              original_triangle_area_mm2: candidate[:original_area_mm2],
              relative_surface_strip_area:
                candidate[:surface_strip_area_mm2] / candidate[:original_area_mm2],
              max_owner_plane_distance_mm: candidate[:max_owner_plane_distance_mm],
              max_normal_deviation_deg: max_deviation
            }
          ]
        end

        def final_boundary_diagnostic(analysis)
          candidate = analysis[:candidate]
          {
            reason: analysis[:reason],
            component: analysis[:component],
            chord: candidate && candidate[:chord],
            chain: candidate && candidate[:path],
            max_chain_distance_mm: candidate && candidate[:max_chain_distance_mm],
            chain_excess_mm: candidate && candidate[:chain_excess_mm],
            surface_strip_area_mm2: candidate && candidate[:surface_strip_area_mm2],
            original_area_mm2: candidate && candidate[:original_area_mm2],
            max_owner_plane_distance_mm: candidate && candidate[:max_owner_plane_distance_mm],
            owner_triangle_index: candidate && candidate[:owner_index],
            source_face_key: candidate && candidate[:source_face_key],
            source_polygon_index: candidate && candidate[:source_polygon_index],
            candidate_count: Array(analysis[:candidates]).length
          }
        end
      end
    end
  end
end
