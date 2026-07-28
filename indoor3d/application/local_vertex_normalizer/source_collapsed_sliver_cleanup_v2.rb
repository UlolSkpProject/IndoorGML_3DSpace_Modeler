# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        SOURCE_COLLAPSED_SLIVER_DIAGNOSTIC_THRESHOLD_MM = 0.5 unless
          const_defined?(:SOURCE_COLLAPSED_SLIVER_DIAGNOSTIC_THRESHOLD_MM, false)

        private

        # Source triangulation is an implementation detail, not source B-rep
        # topology. This stage removes only triangles that have already collapsed
        # naturally to an edge/point (or become exact duplicates). It does not move
        # source vertices and does not force a non-zero-area low-altitude triangle
        # to collapse.
        #
        # The 0.5 mm threshold is diagnostic only. It lets reports identify thin
        # source triangles while keeping source geometry untouched before grid snap.
        def cleanup_source_collapsed_slivers(triangle_records)
          candidates = triangle_records.each_with_index.filter_map do |record, index|
            source_low_altitude_candidate(record, index)
          end

          collapsed, cleanup = discard_collapsed_triangle_records(
            triangle_records,
            coordinate_space: :source
          )

          remaining_slivers = collapsed.each_with_index.count do |record, index|
            !source_low_altitude_candidate(record, index).nil?
          end
          removed_collapsed =
            cleanup[:removed_coincident_triangle_count].to_i +
            cleanup[:removed_collinear_triangle_count].to_i
          removed_duplicates = cleanup[:removed_duplicate_triangle_count].to_i

          report = {
            policy: :natural_collapse_only,
            diagnostic_threshold_mm: SOURCE_COLLAPSED_SLIVER_DIAGNOSTIC_THRESHOLD_MM,
            input_triangle_count: triangle_records.length,
            output_triangle_count: collapsed.length,
            detected_low_altitude_count: candidates.length,
            removed_collapsed_triangle_count: removed_collapsed,
            removed_duplicate_triangle_count: removed_duplicates,
            remaining_low_altitude_count: remaining_slivers,
            moved_vertex_count: 0,
            max_displacement_mm: 0.0,
            affected_source_face_keys:
              Array(cleanup[:affected_source_face_keys]).compact.uniq,
            candidates: candidates.first(20).map do |candidate|
              {
                triangle_index: candidate[:triangle_index],
                source_face_key: candidate[:source_face_key],
                source_polygon_index: candidate[:source_polygon_index],
                minimum_altitude_mm: candidate[:minimum_altitude_mm],
                displacement_mm: candidate[:displacement_mm],
                projection_parameter: candidate[:projection_parameter],
                clamped_parameter: candidate[:clamped_parameter]
              }
            end,
            skipped: cleanup[:removed_triangle_count].to_i.zero?
          }

          [collapsed, report]
        end

        def empty_source_collapsed_sliver_cleanup_report(input_triangle_count = 0)
          {
            policy: :natural_collapse_only,
            diagnostic_threshold_mm: SOURCE_COLLAPSED_SLIVER_DIAGNOSTIC_THRESHOLD_MM,
            input_triangle_count: input_triangle_count,
            output_triangle_count: input_triangle_count,
            detected_low_altitude_count: 0,
            removed_collapsed_triangle_count: 0,
            removed_duplicate_triangle_count: 0,
            remaining_low_altitude_count: 0,
            moved_vertex_count: 0,
            max_displacement_mm: 0.0,
            affected_source_face_keys: [],
            candidates: [],
            skipped: true
          }
        end

        def source_low_altitude_candidate(record, triangle_index)
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
          return nil if minimum_altitude_mm > SOURCE_COLLAPSED_SLIVER_DIAGNOSTIC_THRESHOLD_MM

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

        # Temporary compatibility aliases for existing dev probes and older report
        # readers. Production code should use the new collapsed-sliver naming.
        alias_method :collapse_source_altitude_sliver_triangles,
                     :cleanup_source_collapsed_slivers
        alias_method :empty_source_altitude_sliver_collapse_report,
                     :empty_source_collapsed_sliver_cleanup_report
        alias_method :source_altitude_sliver_candidate,
                     :source_low_altitude_candidate
      end
    end
  end
end
