# frozen_string_literal: true

require_relative '../support/local_vertex_normalizer_test_support'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerTest < Minitest::Test
        def test_exact_coplanar_patch_retriangulates_overlapping_concave_diagonal
          instance = normalizer
          point_a = mm_point(0, 0, 0)
          point_b = mm_point(10, 0, 0)
          point_c = mm_point(10, 10, 0)
          point_d = mm_point(8, 7, 0)
          triangles = []
          add_triangle_record(triangles, point_a, point_b, point_c, :surface)
          add_triangle_record(triangles, point_a, point_c, point_d, :surface)

          rebuilt, report = instance.send(
            :retriangulate_exact_coplanar_patches,
            triangles
          )
          signatures = rebuilt.map do |record|
            record[:points].map { |point| instance.send(:grid_indices, point) }.sort
          end
          expected = [
            [point_a, point_b, point_d],
            [point_b, point_c, point_d]
          ].map do |points|
            points.map { |point| instance.send(:grid_indices, point) }.sort
          end

          assert_equal expected.sort, signatures.sort
          assert_equal 1, report[:rebuilt_patches]
          assert_equal 1, report[:boundary_loops]
          assert_equal 0, report[:holes]
        end

        def test_exact_coplanar_patch_preserves_a_hole_boundary
          instance = normalizer
          outer = [
            mm_point(0, 0, 0),
            mm_point(10, 0, 0),
            mm_point(10, 10, 0),
            mm_point(0, 10, 0)
          ]
          hole = [
            mm_point(3, 3, 0),
            mm_point(7, 3, 0),
            mm_point(7, 7, 0),
            mm_point(3, 7, 0)
          ]
          triangles = []
          [
            [outer[0], outer[1], hole[1]],
            [outer[0], hole[1], hole[0]],
            [outer[1], outer[2], hole[2]],
            [outer[1], hole[2], hole[1]],
            [outer[2], outer[3], hole[3]],
            [outer[2], hole[3], hole[2]],
            [outer[3], outer[0], hole[0]],
            [outer[3], hole[0], hole[3]]
          ].each do |points|
            add_triangle_record(triangles, *points, :ring)
          end

          rebuilt, report = instance.send(
            :retriangulate_exact_coplanar_patch,
            triangles
          )
          validation = instance.send(
            :validate_exact_patch_replacement!,
            rebuilt,
            boundary_edges_for(instance, triangles),
            2
          )

          assert_operator validation, :>=, 0
          assert_equal 8, rebuilt.length
          assert_equal 2, report[:boundary_loops]
          assert_equal 1, report[:holes]
        end

        def test_exact_patch_edge_optimization_replaces_a_bad_internal_diagonal
          instance = normalizer
          point_a = [-1, -100_000, 0]
          point_b = [0, 0, 0]
          point_c = [0, 150, 0]
          point_d = [-100_000, 100_000, 0]
          triangles = [
            [point_a, point_b, point_c],
            [point_a, point_c, point_d]
          ]
          constraints = [
            [point_a, point_b],
            [point_b, point_c],
            [point_c, point_d],
            [point_d, point_a]
          ].to_h do |edge|
            [instance.send(:canonical_edge_key, *edge), true]
          end

          optimized = instance.send(
            :optimize_exact_patch_triangulation,
            triangles,
            constraints,
            2
          )
          constrained_short_edge = [point_b, point_c].sort
          minimum_altitude = optimized.map do |triangle|
            instance.send(:exact_triangle_minimum_altitude_mm, triangle)
          end.min

          refute_includes optimized.map(&:sort), [point_a, point_b, point_c].sort
          assert(
            optimized.any? do |triangle|
              triangle.combination(2).map(&:sort).include?(constrained_short_edge)
            end
          )
          assert_operator minimum_altitude, :>, 0.001
        end

        private
      end
    end
  end
end
