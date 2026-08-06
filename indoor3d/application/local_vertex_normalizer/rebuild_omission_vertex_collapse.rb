# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        MAX_REBUILD_OMISSION_VERTEX_COLLAPSES = 8 unless
          const_defined?(:MAX_REBUILD_OMISSION_VERTEX_COLLAPSES, false)
        MAX_REBUILD_OMISSION_LINE_COMBINATIONS = 4_096 unless
          const_defined?(:MAX_REBUILD_OMISSION_LINE_COMBINATIONS, false)

        private

        unless private_method_defined?(:rebuild_triangles_from_mesh_before_omission_vertex_collapse)
          alias_method :rebuild_triangles_from_mesh_before_omission_vertex_collapse,
                       :rebuild_triangles_from_mesh
        end

        # Normal rebuild behavior is untouched. This fallback is entered only when
        # SketchUp accepted the PolygonMesh but omitted one or more validated
        # triangle Faces. Each repair collapses exactly one omitted triangle's
        # three-vertex cluster to a geometrically supported local intersection,
        # revalidates the complete exact mesh, then retries fill_from_mesh.
        def rebuild_triangles_from_mesh(entities, triangles)
          rebuild_triangles_from_mesh_before_omission_vertex_collapse(
            entities,
            triangles
          )
        rescue ReconstructionError => original_error
          raise unless rebuild_omission_triangle_error?(original_error)

          repair_rebuild_omission_by_vertex_collapse(
            entities,
            triangles,
            original_error
          )
        end

        def repair_rebuild_omission_by_vertex_collapse(
          entities,
          triangles,
          original_error
        )
          working = triangles.map(&:dup)
          repairs = []
          current_error = original_error
          final_mesh_validation = nil

          MAX_REBUILD_OMISSION_VERTEX_COLLAPSES.times do |iteration|
            missing = rebuild_omission_missing_triangle_entries(entities, working)
            break if missing.empty?

            accepted = nil
            rejection_samples = []

            missing.each do |entry|
              candidate = rebuild_omission_vertex_collapse_candidate(
                entities,
                working,
                entry
              )

              if candidate[:accepted]
                accepted = candidate
                break
              end

              rejection_samples << {
                triangle_index: entry[:index],
                signature: entry[:signature],
                reason: candidate[:reason],
                diagnostics: candidate[:diagnostics]
              }
            end

            unless accepted
              raise ReconstructionError,
                    "fill_from_mesh omitted validated triangles and no safe " \
                    "vertex-collapse repair was found: " \
                    "missing=#{missing.length} " \
                    "rejections=#{rejection_samples.first(5).inspect}; " \
                    "original=#{current_error.message}"
            end

            working = accepted.fetch(:triangles)
            final_mesh_validation = accepted.fetch(:mesh_validation)
            repairs << accepted.fetch(:report).merge(iteration: iteration + 1)

            erase_source_geometry(entities)

            begin
              rebuilt =
                rebuild_triangles_from_mesh_before_omission_vertex_collapse(
                  entities,
                  working
                )

              triangles.replace(working)
              aggregate = aggregate_rebuild_omission_vertex_collapse_report(repairs)
              @rebuild_omission_vertex_collapse_report = aggregate
              @rebuild_omission_vertex_collapse_mesh_validation = final_mesh_validation

              return rebuilt.merge(
                strategy: :fill_from_mesh_with_omission_vertex_collapse,
                rebuild_omission_vertex_collapse: aggregate
              )
            rescue ReconstructionError => retry_error
              raise unless rebuild_omission_triangle_error?(retry_error)

              current_error = retry_error
            end
          end

          raise ReconstructionError,
                "fill_from_mesh omission repair exceeded " \
                "#{MAX_REBUILD_OMISSION_VERTEX_COLLAPSES} collapses; " \
                "last=#{current_error.message}"
        end

        def rebuild_omission_triangle_error?(error)
          error.message.start_with?('fill_from_mesh omitted normalized triangles:')
        end

        def rebuild_omission_missing_triangle_entries(entities, records)
          expected = {}
          records.each_with_index do |record, index|
            signature = triangle_signature(record[:points])
            expected[signature] = { index: index, record: record, signature: signature }
          end

          matched = {}
          entities.grep(@face_class).each do |face|
            next unless face&.valid? && face.vertices.length == 3

            signature = triangle_signature(face.vertices.map(&:position))
            matched[signature] = true if expected.key?(signature)
          end

          expected.filter_map do |signature, entry|
            entry unless matched[signature]
          end
        end

        def rebuild_omission_vertex_collapse_candidate(entities, records, entry)
          record = entry.fetch(:record)
          cluster_keys = record[:points].map { |point| grid_indices(point) }

          unless rebuild_omission_triangle_is_open_hole?(entities, cluster_keys)
            return rebuild_omission_rejection(:missing_triangle_is_not_a_simple_open_hole)
          end

          lines_by_vertex = rebuild_omission_external_supporting_lines(cluster_keys, records)
          if lines_by_vertex.any?(&:empty?)
            return rebuild_omission_rejection(
              :cluster_vertex_without_external_edge,
              external_line_counts: lines_by_vertex.map(&:length)
            )
          end

          combination_count = lines_by_vertex.map(&:length).inject(1, :*)
          if combination_count > MAX_REBUILD_OMISSION_LINE_COMBINATIONS
            return rebuild_omission_rejection(
              :too_many_external_line_combinations,
              combination_count: combination_count
            )
          end

          fit = rebuild_omission_best_forward_common_point(lines_by_vertex)
          unless fit
            return rebuild_omission_rejection(
              :no_forward_common_point,
              combination_count: combination_count
            )
          end

          if fit[:max_line_distance_mm] > @tolerance_mm
            return rebuild_omission_rejection(
              :supporting_lines_do_not_converge_within_tolerance,
              max_line_distance_mm: fit[:max_line_distance_mm],
              tolerance_mm: @tolerance_mm
            )
          end

          raw_point = rebuild_omission_point_from_mm(fit[:point_mm])
          snapped_point = normalized_target(raw_point)
          snapped_mm = point_components_mm(snapped_point)
          snap_displacement_mm = rebuild_omission_distance3(fit[:point_mm], snapped_mm)

          if snap_displacement_mm > @tolerance_mm
            return rebuild_omission_rejection(
              :collapse_point_grid_snap_exceeds_tolerance,
              snap_displacement_mm: snap_displacement_mm,
              tolerance_mm: @tolerance_mm
            )
          end

          snapped_line_max = fit[:lines].map do |line|
            rebuild_omission_point_to_line_distance(
              snapped_mm,
              line[:vertex_mm],
              line[:direction]
            )
          end.max || 0.0

          if snapped_line_max > @tolerance_mm
            return rebuild_omission_rejection(
              :snapped_point_leaves_supporting_lines,
              max_line_distance_mm: snapped_line_max,
              tolerance_mm: @tolerance_mm
            )
          end

          cluster_points_mm = record[:points].map { |point| point_components_mm(point) }
          cluster_diameter_mm = 3.times.flat_map do |first|
            ((first + 1)...3).map do |second|
              rebuild_omission_distance3(
                cluster_points_mm[first],
                cluster_points_mm[second]
              )
            end
          end.max || 0.0

          max_vertex_displacement_mm = cluster_points_mm.map do |point|
            rebuild_omission_distance3(point, snapped_mm)
          end.max || 0.0

          if max_vertex_displacement_mm > cluster_diameter_mm + @tolerance_mm
            return rebuild_omission_rejection(
              :collapse_point_is_not_local_to_missing_triangle,
              cluster_diameter_mm: cluster_diameter_mm,
              max_vertex_displacement_mm: max_vertex_displacement_mm
            )
          end

          plane = rebuild_omission_incident_plane_deviation(
            cluster_keys,
            records,
            snapped_mm
          )
          if plane[:max_plane_deviation_mm] > @tolerance_mm
            return rebuild_omission_rejection(
              :collapse_moves_surviving_face_off_supporting_plane,
              max_plane_deviation_mm: plane[:max_plane_deviation_mm],
              tolerance_mm: @tolerance_mm
            )
          end

          cluster_lookup = cluster_keys.to_h { |key| [key, true] }
          candidate = records.map do |source_record|
            changed = false
            points = source_record[:points].map do |point|
              if cluster_lookup[grid_indices(point)]
                changed = true
                snapped_point
              else
                point
              end
            end

            changed ? source_record.merge(
              points: points,
              rebuild_omission_vertex_collapse: true
            ) : source_record
          end

          cleaned, cleanup = discard_collapsed_triangle_records(candidate)

          if cleanup[:removed_coincident_triangle_count].to_i.zero?
            return rebuild_omission_rejection(:collapse_removed_no_degenerate_triangles)
          end
          if cleanup[:removed_collinear_triangle_count].to_i.positive?
            return rebuild_omission_rejection(
              :collapse_created_collinear_triangle_removal,
              cleanup: cleanup
            )
          end
          if cleanup[:removed_duplicate_triangle_count].to_i.positive?
            return rebuild_omission_rejection(
              :collapse_created_duplicate_triangle_removal,
              cleanup: cleanup
            )
          end

          collapse_key = grid_indices(snapped_point)
          unless rebuild_omission_collapse_link_single_cycle?(cleaned, collapse_key)
            return rebuild_omission_rejection(:collapsed_vertex_link_is_not_single_cycle)
          end

          begin
            mesh_validation = validate_normalized_triangle_mesh!(cleaned)
          rescue Error, ArgumentError => error
            return rebuild_omission_rejection(
              :collapsed_mesh_failed_exact_hard_gate,
              error: "#{error.class}: #{error.message}"
            )
          end

          {
            accepted: true,
            triangles: cleaned,
            mesh_validation: mesh_validation,
            report: {
              trigger: :fill_from_mesh_omitted_triangle,
              missing_triangle_index: entry[:index],
              missing_signature: entry[:signature],
              source_face_key: record[:source_face_key],
              source_polygon_index: record[:source_polygon_index],
              cluster_keys: cluster_keys,
              collapse_key: collapse_key,
              raw_collapse_point_mm: fit[:point_mm],
              snapped_collapse_point_mm: snapped_mm,
              external_line_counts: lines_by_vertex.map(&:length),
              tested_line_combinations: combination_count,
              forward_line_combinations: fit[:forward_combination_count],
              line_rms_residual_mm: fit[:rms_line_distance_mm],
              line_max_residual_mm: fit[:max_line_distance_mm],
              snapped_line_max_residual_mm: snapped_line_max,
              grid_snap_displacement_mm: snap_displacement_mm,
              cluster_diameter_mm: cluster_diameter_mm,
              max_vertex_displacement_mm: max_vertex_displacement_mm,
              max_incident_plane_deviation_mm: plane[:max_plane_deviation_mm],
              incident_plane_sample_count: plane[:sample_count],
              removed_coincident_triangle_count:
                cleanup[:removed_coincident_triangle_count].to_i,
              removed_collinear_triangle_count:
                cleanup[:removed_collinear_triangle_count].to_i,
              removed_duplicate_triangle_count:
                cleanup[:removed_duplicate_triangle_count].to_i,
              affected_source_face_keys: Array(cleanup[:affected_source_face_keys]),
              triangle_count_before: records.length,
              triangle_count_after: cleaned.length,
              mesh_validation: mesh_validation
            }
          }
        end

        def rebuild_omission_rejection(reason, diagnostics = {})
          { accepted: false, reason: reason, diagnostics: diagnostics }
        end

        # Only a genuine triangular hole is eligible. Absorbed n-gons, missing
        # vertices, and more complex partial-fill changes are deliberately left to
        # rollback rather than being interpreted as a small-Face collapse.
        def rebuild_omission_triangle_is_open_hole?(entities, cluster_keys)
          vertices = {}
          edge_by_key = {}

          entities.grep(@edge_class).each do |edge|
            next unless edge&.valid?

            first = grid_indices(edge.start.position)
            second = grid_indices(edge.end.position)
            vertices[first] = true
            vertices[second] = true
            edge_by_key[canonical_edge_key(first, second)] = edge
          end

          return false unless cluster_keys.all? { |key| vertices[key] }

          3.times.all? do |index|
            edge = edge_by_key[
              canonical_edge_key(cluster_keys[index], cluster_keys[(index + 1) % 3])
            ]
            edge&.valid? && edge.faces.count { |face| face&.valid? } == 1
          end
        end

        def rebuild_omission_external_supporting_lines(cluster_keys, records)
          cluster_lookup = cluster_keys.to_h { |key| [key, true] }
          point_by_key = {}
          records.each do |record|
            record[:points].each do |point|
              key = grid_indices(point)
              point_by_key[key] ||= point
            end
          end

          cluster_keys.map do |vertex_key|
            neighbors = {}

            records.each_with_index do |record, triangle_index|
              keys = record[:points].map { |point| grid_indices(point) }
              next unless keys.include?(vertex_key)

              keys.each do |neighbor_key|
                next if neighbor_key == vertex_key || cluster_lookup[neighbor_key]

                neighbors[neighbor_key] ||= []
                neighbors[neighbor_key] << triangle_index
              end
            end

            vertex_mm = point_components_mm(point_by_key.fetch(vertex_key))
            neighbors.filter_map do |neighbor_key, triangle_indices|
              neighbor_mm = point_components_mm(point_by_key.fetch(neighbor_key))
              vector = rebuild_omission_subtract3(vertex_mm, neighbor_mm)
              length = rebuild_omission_norm3(vector)
              next if length <= 0.0

              {
                vertex_key: vertex_key,
                neighbor_key: neighbor_key,
                vertex_mm: vertex_mm,
                neighbor_mm: neighbor_mm,
                direction: vector.map { |value| value / length },
                triangle_indices: triangle_indices.uniq.sort
              }
            end
          end
        end

        def rebuild_omission_best_forward_common_point(lines_by_vertex)
          candidates = []
          lines_by_vertex[0].product(lines_by_vertex[1], lines_by_vertex[2]).each do |lines|
            fit = rebuild_omission_fit_common_point_to_lines(lines)
            next unless fit
            next unless fit[:extensions_mm].all? { |value| value >= -GRID_EPSILON_MM }

            candidates << fit.merge(lines: lines)
          end
          return nil if candidates.empty?

          candidates.sort_by! do |candidate|
            [candidate[:rms_line_distance_mm], candidate[:max_line_distance_mm]]
          end
          best = candidates.first
          best.merge(forward_combination_count: candidates.length)
        end

        def rebuild_omission_fit_common_point_to_lines(lines)
          matrix = Array.new(3) { Array.new(3, 0.0) }
          vector = [0.0, 0.0, 0.0]

          lines.each do |line|
            direction = line[:direction]
            point = line[:vertex_mm]
            projector = Array.new(3) do |row|
              Array.new(3) do |column|
                (row == column ? 1.0 : 0.0) -
                  (direction[row] * direction[column])
              end
            end

            3.times do |row|
              3.times do |column|
                matrix[row][column] += projector[row][column]
              end
              vector[row] += projector[row][0] * point[0] +
                projector[row][1] * point[1] +
                projector[row][2] * point[2]
            end
          end

          point = rebuild_omission_solve_3x3(matrix, vector)
          return nil unless point

          distances = lines.map do |line|
            rebuild_omission_point_to_line_distance(
              point,
              line[:vertex_mm],
              line[:direction]
            )
          end
          extensions = lines.map do |line|
            rebuild_omission_dot3(
              rebuild_omission_subtract3(point, line[:vertex_mm]),
              line[:direction]
            )
          end

          {
            point_mm: point,
            rms_line_distance_mm: Math.sqrt(
              distances.sum { |distance| distance * distance } / distances.length.to_f
            ),
            max_line_distance_mm: distances.max || 0.0,
            extensions_mm: extensions
          }
        end

        def rebuild_omission_incident_plane_deviation(cluster_keys, records, collapse_mm)
          cluster_lookup = cluster_keys.to_h { |key| [key, true] }
          distances = []

          records.each do |record|
            keys = record[:points].map { |point| grid_indices(point) }
            next unless keys.count { |key| cluster_lookup[key] } == 1

            points = record[:points].map { |point| point_components_mm(point) }
            normal = rebuild_omission_cross3(
              rebuild_omission_subtract3(points[1], points[0]),
              rebuild_omission_subtract3(points[2], points[0])
            )
            length = rebuild_omission_norm3(normal)
            next unless length.positive?

            distances << (
              rebuild_omission_dot3(
                normal,
                rebuild_omission_subtract3(collapse_mm, points[0])
              ).abs / length
            )
          end

          {
            sample_count: distances.length,
            max_plane_deviation_mm: distances.max || 0.0
          }
        end

        def rebuild_omission_collapse_link_single_cycle?(records, collapse_key)
          adjacency = Hash.new { |hash, key| hash[key] = [] }

          records.each do |record|
            keys = record[:points].map { |point| grid_indices(point) }
            next unless keys.include?(collapse_key)

            others = keys.reject { |key| key == collapse_key }
            return false unless others.length == 2

            first, second = others
            adjacency[first] << second
            adjacency[second] << first
          end

          return false if adjacency.empty?
          return false unless adjacency.values.all? { |neighbors| neighbors.uniq.length == 2 }

          seed = adjacency.keys.first
          visited = { seed => true }
          queue = [seed]
          until queue.empty?
            current = queue.shift
            adjacency[current].uniq.each do |neighbor|
              next if visited[neighbor]

              visited[neighbor] = true
              queue << neighbor
            end
          end

          visited.length == adjacency.length
        end

        def aggregate_rebuild_omission_vertex_collapse_report(repairs)
          {
            attempted: true,
            accepted: true,
            trigger: :fill_from_mesh_omitted_triangles,
            repair_count: repairs.length,
            repairs: repairs,
            removed_coincident_triangle_count: repairs.sum do |repair|
              repair[:removed_coincident_triangle_count].to_i
            end,
            removed_collinear_triangle_count: repairs.sum do |repair|
              repair[:removed_collinear_triangle_count].to_i
            end,
            removed_duplicate_triangle_count: repairs.sum do |repair|
              repair[:removed_duplicate_triangle_count].to_i
            end,
            affected_source_face_keys: repairs.flat_map do |repair|
              Array(repair[:affected_source_face_keys])
            end.compact.uniq,
            max_vertex_displacement_mm: repairs.map do |repair|
              repair[:max_vertex_displacement_mm].to_f
            end.max || 0.0,
            max_incident_plane_deviation_mm: repairs.map do |repair|
              repair[:max_incident_plane_deviation_mm].to_f
            end.max || 0.0,
            max_line_residual_mm: repairs.map do |repair|
              repair[:line_max_residual_mm].to_f
            end.max || 0.0
          }
        end

        unless private_method_defined?(:build_normalization_report_before_omission_vertex_collapse)
          alias_method :build_normalization_report_before_omission_vertex_collapse,
                       :build_normalization_report
        end

        def build_normalization_report(*args, **kwargs)
          repair = @rebuild_omission_vertex_collapse_report
          validation = @rebuild_omission_vertex_collapse_mesh_validation
          kwargs = kwargs.merge(mesh_validation: validation) if repair && validation

          report = build_normalization_report_before_omission_vertex_collapse(*args, **kwargs)
          return report unless repair

          report[:rebuild_omission_vertex_collapse] = repair
          report[:max_displacement_mm] = [
            report[:max_displacement_mm].to_f,
            repair[:max_vertex_displacement_mm].to_f
          ].max
          report[:collapsed_triangle_removal_count] =
            report[:collapsed_triangle_removal_count].to_i +
            repair[:removed_coincident_triangle_count].to_i

          if report[:normalization_passes].is_a?(Array)
            report[:normalization_passes] << {
              phase: :rebuild_omission_vertex_collapse,
              trigger: repair[:trigger],
              repair_count: repair[:repair_count],
              removed_degenerate_triangles:
                repair[:removed_coincident_triangle_count],
              max_vertex_displacement_mm:
                repair[:max_vertex_displacement_mm],
              max_incident_plane_deviation_mm:
                repair[:max_incident_plane_deviation_mm],
              max_line_residual_mm:
                repair[:max_line_residual_mm]
            }
          end

          report
        end

        def rebuild_omission_point_from_mm(point)
          @point_factory.call(
            point[0] / MM_PER_INCH,
            point[1] / MM_PER_INCH,
            point[2] / MM_PER_INCH
          )
        end

        def rebuild_omission_subtract3(first, second)
          [
            first[0] - second[0],
            first[1] - second[1],
            first[2] - second[2]
          ]
        end

        def rebuild_omission_dot3(first, second)
          (first[0] * second[0]) +
            (first[1] * second[1]) +
            (first[2] * second[2])
        end

        def rebuild_omission_cross3(first, second)
          [
            (first[1] * second[2]) - (first[2] * second[1]),
            (first[2] * second[0]) - (first[0] * second[2]),
            (first[0] * second[1]) - (first[1] * second[0])
          ]
        end

        def rebuild_omission_norm3(vector)
          Math.sqrt(rebuild_omission_dot3(vector, vector))
        end

        def rebuild_omission_distance3(first, second)
          rebuild_omission_norm3(rebuild_omission_subtract3(first, second))
        end

        def rebuild_omission_point_to_line_distance(point, anchor, direction)
          offset = rebuild_omission_subtract3(point, anchor)
          along = rebuild_omission_dot3(offset, direction)
          perpendicular = [
            offset[0] - (direction[0] * along),
            offset[1] - (direction[1] * along),
            offset[2] - (direction[2] * along)
          ]
          rebuild_omission_norm3(perpendicular)
        end

        def rebuild_omission_solve_3x3(matrix, vector)
          augmented = 3.times.map do |row|
            [
              matrix[row][0].to_f,
              matrix[row][1].to_f,
              matrix[row][2].to_f,
              vector[row].to_f
            ]
          end

          3.times do |column|
            pivot_row = (column...3).max_by { |row| augmented[row][column].abs }
            return nil if augmented[pivot_row][column].abs < 1.0e-12

            if pivot_row != column
              augmented[column], augmented[pivot_row] =
                augmented[pivot_row], augmented[column]
            end

            divisor = augmented[column][column]
            column.upto(3) do |index|
              augmented[column][index] /= divisor
            end

            3.times do |row|
              next if row == column

              factor = augmented[row][column]
              column.upto(3) do |index|
                augmented[row][index] -= factor * augmented[column][index]
              end
            end
          end

          [augmented[0][3], augmented[1][3], augmented[2][3]]
        end
      end
    end
  end
end
