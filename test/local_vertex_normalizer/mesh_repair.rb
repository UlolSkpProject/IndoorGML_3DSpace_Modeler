# frozen_string_literal: true

require_relative '../support/local_vertex_normalizer_test_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTest < Minitest::Test
        def test_exact_duplicate_mesh_triangles_are_canonicalized_before_manifold_validation
          points = [
            mm_point(0, 0, 0),
            mm_point(10, 0, 0),
            mm_point(0, 10, 0)
          ]
          face = SnapshotFace.new(points, [[1, 2, 3], [1, 2, 3]], 501)
          diagnostics = {}
          instance = normalizer(face_class: SnapshotFace)

          triangles = instance.send(
            :normalized_triangle_snapshot,
            SnapshotEntities.new([face]),
            duplicate_diagnostics: diagnostics
          )

          assert_equal 1, triangles.length
          assert_equal 1, diagnostics[:duplicate_count]
          assert_equal 501, diagnostics.dig(:samples, 0, :kept_face_key)
          assert_equal 501, diagnostics.dig(:samples, 0, :duplicate_face_key)
        end

        def test_canonicalized_duplicate_mesh_still_requires_a_closed_two_manifold
          faces = tetrahedron_faces.each_with_index.map do |points, index|
            polygons = index.zero? ? [[1, 2, 3], [1, 2, 3]] : [[1, 2, 3]]
            SnapshotFace.new(points, polygons, 600 + index)
          end
          diagnostics = {}
          instance = normalizer(face_class: SnapshotFace)
          triangles = instance.send(
            :normalized_triangle_snapshot,
            SnapshotEntities.new(faces),
            duplicate_diagnostics: diagnostics
          )

          validation = instance.send(:validate_normalized_triangle_mesh!, triangles)

          assert_equal 1, diagnostics[:duplicate_count]
          assert_equal 4, validation[:triangle_count]
          assert_equal 1, validation[:component_count]
        end

        def test_degenerate_mesh_fan_uses_the_short_boundary_edges_and_alternate_diagonal
          points = [
            mm_point(0, 0, 0),
            mm_point(5, 0, 0),
            mm_point(10, 0, 0),
            mm_point(0, 10, 0)
          ]
          face = SnapshotFace.new(points, [[1, 2, 3], [1, 3, 4]], 701)
          instance = normalizer(face_class: SnapshotFace)
          triangles = instance.send(
            :normalized_triangle_snapshot,
            SnapshotEntities.new([face])
          )

          repaired, report = instance.send(
            :repair_degenerate_source_triangles,
            triangles
          )
          signatures = repaired.map do |record|
            record[:points].map { |point| instance.send(:grid_indices, point) }.sort
          end
          expected = [
            [[0, 0, 0], [5_000, 0, 0], [0, 10_000, 0]].sort,
            [[5_000, 0, 0], [10_000, 0, 0], [0, 10_000, 0]].sort
          ]

          assert_equal 1, report[:repaired_triangles]
          assert_equal 1, report[:replaced_pairs]
          assert_equal expected.sort, signatures.sort
          refute repaired.any? { |record| instance.send(:degenerate_triangle_record?, record) }
        end

        def test_source_space_degenerate_triangle_is_repaired_before_grid_rounding
          point_p = mm_point(30_374.309310100576, -5_125.200161758802, -400)
          point_a = mm_point(33_074.02490280663, -5_086.011917351332, -400)
          point_b = mm_point(35_845.88451831048, -5_045.776452412334, -400)
          point_q = mm_point(16_475.775270217444, -5_326.94702366224, 3_800)
          face = SnapshotFace.new(
            [point_p, point_a, point_b, point_q],
            [[1, 2, 3], [1, 3, 4]],
            702
          )
          instance = normalizer(face_class: SnapshotFace)
          source = instance.send(:triangle_snapshot, SnapshotEntities.new([face]))

          assert instance.send(
            :degenerate_triangle_record?,
            source.first,
            coordinate_space: :source
          )

          rounded_without_repair = instance.send(:normalize_triangle_records, source)
          refute instance.send(
            :degenerate_triangle_record?,
            rounded_without_repair.first
          )

          repaired, report = instance.send(
            :repair_degenerate_source_triangles,
            source,
            coordinate_space: :source
          )
          normalized = instance.send(:normalize_triangle_records, repaired)
          point_p_key = instance.send(:grid_indices, point_p)
          point_b_key = instance.send(:grid_indices, point_b)
          long_edge = [point_p_key, point_b_key].sort
          normalized_edges = normalized.flat_map do |record|
            triangle = record[:points].map do |point|
              instance.send(:grid_indices, point)
            end
            3.times.map do |index|
              [triangle[index], triangle[(index + 1) % 3]].sort
            end
          end

          assert_equal 1, report[:repaired_triangles]
          assert_equal 1, report[:replaced_pairs]
          refute_includes normalized_edges, long_edge
          refute normalized.any? { |record| instance.send(:degenerate_triangle_record?, record) }
        end

        def test_triangle_collapsed_by_grid_rounding_is_repaired_after_normalization
          point_p = mm_point(0, 0, 0)
          point_a = mm_point(5, 0.0004, 0)
          point_b = mm_point(10, 0, 0)
          point_q = mm_point(0, 10, 0)
          face = SnapshotFace.new(
            [point_p, point_a, point_b, point_q],
            [[1, 2, 3], [1, 3, 4]],
            703
          )
          instance = normalizer(face_class: SnapshotFace)
          source = instance.send(:triangle_snapshot, SnapshotEntities.new([face]))
          source_repaired, source_report = instance.send(
            :repair_degenerate_source_triangles,
            source,
            coordinate_space: :source
          )

          assert_equal 0, source_report[:repaired_triangles]

          normalized = instance.send(:normalize_triangle_records, source_repaired)
          assert instance.send(:degenerate_triangle_record?, normalized.first)

          repaired, report = instance.send(
            :repair_degenerate_source_triangles,
            normalized
          )

          assert_equal 1, report[:repaired_triangles]
          assert_equal 1, report[:replaced_pairs]
          refute repaired.any? { |record| instance.send(:degenerate_triangle_record?, record) }
        end

        def test_degenerate_repair_report_aggregates_each_mesh_stage
          instance = normalizer
          report = instance.send(
            :aggregate_degenerate_repair_reports,
            source: { repaired_triangles: 1, replaced_pairs: 1 },
            conforming: { repaired_triangles: 0, replaced_pairs: 0 },
            rebuilt: { repaired_triangles: 0, replaced_pairs: 0 },
            final: { repaired_triangles: 2, replaced_pairs: 2 }
          )

          assert_equal 3, report[:repaired_triangles]
          assert_equal 3, report[:replaced_pairs]
          assert_equal 2, report.dig(:stages, :final, :repaired_triangles)
        end
      end
    end
  end
end
