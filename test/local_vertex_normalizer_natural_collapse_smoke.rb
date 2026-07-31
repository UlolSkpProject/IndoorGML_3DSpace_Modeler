# frozen_string_literal: true

# Standalone policy smoke test for source-space triangulation collapse handling.
# A non-zero-area low-altitude triangle is diagnostic only and must not be
# projected onto an edge. A triangle that is already zero-area is disposable.

NaturalCollapsePoint = Struct.new(:x, :y, :z)

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_EPSILON_MM = 0.000001
        MM_PER_INCH = 1.0

        def initialize
          @point_factory = ->(x, y, z) { NaturalCollapsePoint.new(x, y, z) }
        end

        def point_distance_mm(point_a, point_b)
          Math.sqrt(
            ((point_a.x - point_b.x)**2) +
            ((point_a.y - point_b.y)**2) +
            ((point_a.z - point_b.z)**2)
          )
        end

        def vector_between(point_a, point_b)
          [
            point_b.x - point_a.x,
            point_b.y - point_a.y,
            point_b.z - point_a.z
          ]
        end

        def vector_dot(vector_a, vector_b)
          vector_a.zip(vector_b).sum { |first, second| first * second }
        end

        def vector_cross(vector_a, vector_b)
          [
            (vector_a[1] * vector_b[2]) - (vector_a[2] * vector_b[1]),
            (vector_a[2] * vector_b[0]) - (vector_a[0] * vector_b[2]),
            (vector_a[0] * vector_b[1]) - (vector_a[1] * vector_b[0])
          ]
        end

        def vector_length(vector)
          Math.sqrt(vector_dot(vector, vector))
        end

        def source_point_key(point)
          [point.x, point.y, point.z]
        end

        def source_precision_indices(point)
          [point.x, point.y, point.z].map do |coordinate|
            (coordinate / GRID_EPSILON_MM).round
          end
        end

        def discard_collapsed_triangle_records(
          triangle_records,
          coordinate_space: :grid,
          duplicate_diagnostics: nil
        )
          raise 'natural-collapse smoke expects source coordinates' unless
            coordinate_space == :source

          signatures = {}
          removed_coincident = 0
          removed_collinear = 0
          removed_duplicate = 0
          affected_source_face_keys = []

          records = triangle_records.filter_map do |record|
            keys = record[:points].map { |point| source_precision_indices(point) }
            if keys.uniq.length != 3
              removed_coincident += 1
              affected_source_face_keys << record[:source_face_key]
              next
            end

            if source_triangle_collapsed_to_edge?(record[:points])
              removed_collinear += 1
              affected_source_face_keys << record[:source_face_key]
              next
            end

            signature = keys.sort
            if signatures.key?(signature)
              removed_duplicate += 1
              affected_source_face_keys << record[:source_face_key]
              next
            end

            signatures[signature] = true
            record
          end

          removed_count = removed_coincident + removed_collinear + removed_duplicate
          [
            records,
            {
              removed_coincident_triangle_count: removed_coincident,
              removed_collinear_triangle_count: removed_collinear,
              removed_duplicate_triangle_count: removed_duplicate,
              removed_triangle_count: removed_count,
              affected_source_face_keys: affected_source_face_keys.compact.uniq
            }
          ]
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/source_collapsed_sliver_cleanup_v2'

normalizer = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer.new

sliver = {
  points: [
    NaturalCollapsePoint.new(0.0, 0.0, 0.0),
    NaturalCollapsePoint.new(5.0, 0.1, 0.0),
    NaturalCollapsePoint.new(10.0, 0.0, 0.0)
  ],
  source_face_key: 1,
  source_polygon_index: 0
}
sliver_points_before = sliver[:points].map { |point| [point.x, point.y, point.z] }
records, report = normalizer.send(:cleanup_source_collapsed_slivers, [sliver])
sliver_points_after = records.first[:points].map { |point| [point.x, point.y, point.z] }

raise 'non-zero source sliver was removed' unless records.length == 1
raise 'non-zero source sliver was moved' unless sliver_points_after == sliver_points_before
raise 'source sliver reported a moved vertex' unless report[:moved_vertex_count].zero?
raise 'source sliver should remain diagnostic-only' unless report[:remaining_sliver_count] == 1
raise 'unexpected source sliver policy' unless report[:policy] == :natural_collapse_only

collapsed = {
  points: [
    NaturalCollapsePoint.new(0.0, 0.0, 0.0),
    NaturalCollapsePoint.new(5.0, 0.0, 0.0),
    NaturalCollapsePoint.new(10.0, 0.0, 0.0)
  ],
  source_face_key: 2,
  source_polygon_index: 0
}
records, report = normalizer.send(:cleanup_source_collapsed_slivers, [collapsed])

raise 'zero-area source triangle was retained' unless records.empty?
raise 'zero-area source triangle removal was not reported' unless
  report[:removed_collapsed_triangle_count] == 1
raise 'zero-area cleanup moved a vertex' unless report[:moved_vertex_count].zero?

puts 'LocalVertexNormalizer natural collapse smoke test: OK'
