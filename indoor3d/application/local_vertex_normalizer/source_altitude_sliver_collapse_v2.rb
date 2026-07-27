# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        SOURCE_ALTITUDE_SLIVER_THRESHOLD_MM = 0.5 unless
          const_defined?(:SOURCE_ALTITUDE_SLIVER_THRESHOLD_MM, false)

        private

        # Collapses a source-space triangle whose minimum altitude is at most
        # 0.5 mm. For the longest edge C, the opposite vertex (where A and B
        # meet) is moved to its clamped perpendicular projection on C. Every
        # triangle using that source vertex receives the same target. Triangles
        # reduced to an edge and exact duplicate triangles are then discarded.
        #
        # All candidates are measured from the same input snapshot and applied
        # simultaneously. If one vertex is the apex of multiple slivers, the
        # smallest-altitude candidate wins deterministically.
        def collapse_source_altitude_sliver_triangles(triangle_records)
          candidates = triangle_records.each_with_index.filter_map do |record, index|
            source_altitude_sliver_candidate(record, index)
          end
          if candidates.empty?
            return [
              triangle_records,
              empty_source_altitude_sliver_collapse_report(
                triangle_records.length
              )
            ]
          end

          grouped = candidates.group_by { |candidate| candidate[:apex_key] }
          conflicting_target_count = grouped.count do |_key, vertex_candidates|
            vertex_candidates.map do |candidate|
              source_precision_indices(candidate[:target])
            end.uniq.length > 1
          end

          affected_source_face_keys = []
          moved_record_count = 0
          removed_collapsed = 0
          removed_duplicates = 0
          moved_apex_keys = {}
          selected_apex_keys = {}
          selected_candidates = []
          max_displacement_mm = 0.0
          collapsed = triangle_records
          iteration_limit = [triangle_records.length, 1].max
          iterations = 0

          loop do
            current_candidates = collapsed.each_with_index.filter_map do |record, index|
              source_altitude_sliver_candidate(record, index)
            end
            break if current_candidates.empty?

            candidate = current_candidates.min_by do |entry|
              [
                entry[:minimum_altitude_mm],
                entry[:displacement_mm],
                entry[:triangle_index],
                source_point_key(entry[:target])
              ]
            end
            selected_candidates << candidate
            selected_apex_keys[candidate[:apex_key]] = true
            if candidate[:displacement_mm] > GRID_EPSILON_MM
              moved_apex_keys[candidate[:apex_key]] = true
            end
            max_displacement_mm = [
              max_displacement_mm,
              candidate[:displacement_mm]
            ].max

            moved_records = collapsed.map do |record|
              moved = false
              points = record[:points].map do |point|
                next point unless
                  source_point_key(point) == candidate[:apex_key]

                moved = true
                candidate[:target]
              end
              if moved
                moved_record_count += 1
                affected_source_face_keys << record[:source_face_key]
                record.merge(points: points)
              else
                record
              end
            end

            signatures = {}
            previous_length = collapsed.length
            collapsed = moved_records.filter_map do |record|
              if source_triangle_collapsed_to_edge?(record[:points])
                removed_collapsed += 1
                affected_source_face_keys << record[:source_face_key]
                next
              end

              signature = record[:points].map do |point|
                source_precision_indices(point)
              end.sort
              if signatures.key?(signature)
                removed_duplicates += 1
                affected_source_face_keys << record[:source_face_key]
                affected_source_face_keys <<
                  signatures[signature][:source_face_key]
                next
              end

              signatures[signature] = record
              record
            end
            unless collapsed.length < previous_length
              raise ReconstructionError,
                    'Source altitude sliver collapse made no topological progress'
            end

            iterations += 1
            if iterations > iteration_limit
              raise ReconstructionError,
                    'Source altitude sliver collapse exceeded its iteration limit'
            end
          end

          remaining_slivers = collapsed.each_with_index.count do |record, index|
            !source_altitude_sliver_candidate(record, index).nil?
          end

          [
            collapsed,
            {
              threshold_mm: SOURCE_ALTITUDE_SLIVER_THRESHOLD_MM,
              input_triangle_count: triangle_records.length,
              output_triangle_count: collapsed.length,
              detected_sliver_count: candidates.length,
              collapse_step_count: iterations,
              selected_apex_count: selected_apex_keys.length,
              moved_vertex_count: moved_apex_keys.length,
              moved_triangle_count: moved_record_count,
              conflicting_target_count: conflicting_target_count,
              removed_collapsed_triangle_count: removed_collapsed,
              removed_duplicate_triangle_count: removed_duplicates,
              remaining_sliver_count: remaining_slivers,
              max_displacement_mm: max_displacement_mm,
              affected_source_face_keys:
                affected_source_face_keys.compact.uniq,
              candidates: selected_candidates.first(20).map do |candidate|
                {
                  triangle_index: candidate[:triangle_index],
                  source_face_key: candidate[:source_face_key],
                  source_polygon_index: candidate[:source_polygon_index],
                  minimum_altitude_mm:
                    candidate[:minimum_altitude_mm],
                  displacement_mm: candidate[:displacement_mm],
                  projection_parameter:
                    candidate[:projection_parameter],
                  clamped_parameter: candidate[:clamped_parameter]
                }
              end,
              skipped: false
            }
          ]
        end

        def empty_source_altitude_sliver_collapse_report(input_triangle_count = 0)
          {
            threshold_mm: SOURCE_ALTITUDE_SLIVER_THRESHOLD_MM,
            input_triangle_count: input_triangle_count,
            output_triangle_count: input_triangle_count,
            detected_sliver_count: 0,
            collapse_step_count: 0,
            selected_apex_count: 0,
            moved_vertex_count: 0,
            moved_triangle_count: 0,
            conflicting_target_count: 0,
            removed_collapsed_triangle_count: 0,
            removed_duplicate_triangle_count: 0,
            remaining_sliver_count: 0,
            max_displacement_mm: 0.0,
            affected_source_face_keys: [],
            candidates: [],
            skipped: true
          }
        end

        def source_altitude_sliver_candidate(record, triangle_index)
          points = record[:points]
          return nil unless points.length == 3

          edges = [
            [0, 1, 2],
            [1, 2, 0],
            [2, 0, 1]
          ].map do |start_index, end_index, apex_index|
            [
              point_distance_mm(points[start_index], points[end_index]),
              start_index,
              end_index,
              apex_index
            ]
          end
          longest, start_index, end_index, apex_index = edges.max_by do |entry|
            [entry[0], -entry[3]]
          end
          return nil unless longest > GRID_EPSILON_MM

          normal = vector_cross(
            vector_between(points[0], points[1]),
            vector_between(points[0], points[2])
          )
          minimum_altitude_mm = (
            vector_length(normal) * (MM_PER_INCH**2)
          ) / longest
          return nil if
            minimum_altitude_mm > SOURCE_ALTITUDE_SLIVER_THRESHOLD_MM

          edge_start = points[start_index]
          edge_end = points[end_index]
          apex = points[apex_index]
          direction = vector_between(edge_start, edge_end)
          offset = vector_between(edge_start, apex)
          length_squared = vector_dot(direction, direction)
          return nil unless length_squared.positive?

          parameter = vector_dot(offset, direction) / length_squared
          clamped_parameter = [[parameter, 0.0].max, 1.0].min
          target = @point_factory.call(
            edge_start.x.to_f + (direction[0] * clamped_parameter),
            edge_start.y.to_f + (direction[1] * clamped_parameter),
            edge_start.z.to_f + (direction[2] * clamped_parameter)
          )

          {
            triangle_index: triangle_index,
            source_face_key: record[:source_face_key],
            source_polygon_index: record[:source_polygon_index],
            apex_key: source_point_key(apex),
            apex: apex,
            target: target,
            minimum_altitude_mm: minimum_altitude_mm,
            displacement_mm: point_distance_mm(apex, target),
            projection_parameter: parameter,
            clamped_parameter: clamped_parameter
          }
        end

        def source_triangle_collapsed_to_edge?(points)
          keys = points.map { |point| source_precision_indices(point) }
          return true if keys.uniq.length != 3

          longest = 3.times.map do |index|
            point_distance_mm(points[index], points[(index + 1) % 3])
          end.max
          return true unless longest&.positive?

          normal = vector_cross(
            vector_between(points[0], points[1]),
            vector_between(points[0], points[2])
          )
          altitude_mm = (
            vector_length(normal) * (MM_PER_INCH**2)
          ) / longest
          altitude_mm <= GRID_EPSILON_MM
        end
      end
    end
  end
end
