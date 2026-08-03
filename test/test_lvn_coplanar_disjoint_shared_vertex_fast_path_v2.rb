# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end unless const_defined?(:Edge, false)
  class Face; end unless const_defined?(:Face, false)
end

require_relative '../indoor3d/application/local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LvnCoplanarDisjointSharedVertexFastPathV2Test < Minitest::Test
        def setup
          @normalizer = LocalVertexNormalizer.new
        end

        def test_aabb_overlapping_disjoint_triangles_are_proven_clean
          triangle_a = triangle([0, 0], [4, 0], [0, 4])
          triangle_b = triangle([3, 3], [5, 3], [3, 5])

          assert_equal true,
                       @normalizer.send(
                         :coplanar_disjoint_intersection_decision_v2,
                         triangle_a,
                         triangle_b
                       )
          assert legacy_allowed?(triangle_a, triangle_b, [])
        end

        def test_nonshared_touch_falls_back_to_reference_predicate
          triangle_a = triangle([-1, -1], [0, 0], [-1, 0])
          triangle_b = triangle([-1, 1], [1, -1], [-1, 2])

          assert_nil @normalizer.send(
            :coplanar_disjoint_intersection_decision_v2,
            triangle_a,
            triangle_b
          )
          refute legacy_allowed?(triangle_a, triangle_b, [])
        end

        def test_overlapping_disjoint_vertex_sets_fall_back
          triangle_a = triangle([0, 0], [4, 0], [0, 4])
          triangle_b = triangle([1, 1], [5, 1], [1, 5])

          assert_nil @normalizer.send(
            :coplanar_disjoint_intersection_decision_v2,
            triangle_a,
            triangle_b
          )
          refute legacy_allowed?(triangle_a, triangle_b, [])
        end

        def test_shared_vertex_only_contact_is_proven_clean
          shared = point(0, 0)
          triangle_a = [shared, point(4, 0), point(0, 4)]
          triangle_b = [shared, point(-4, 0), point(0, -4)]

          assert_equal true,
                       @normalizer.send(
                         :coplanar_shared_vertex_intersection_decision_v2,
                         triangle_a,
                         triangle_b,
                         shared
                       )
          assert legacy_allowed?(triangle_a, triangle_b, [shared])
        end

        def test_shared_vertex_with_area_overlap_falls_back
          shared = point(0, 0)
          triangle_a = [shared, point(4, 0), point(0, 4)]
          triangle_b = [shared, point(4, 1), point(1, 4)]

          assert_nil @normalizer.send(
            :coplanar_shared_vertex_intersection_decision_v2,
            triangle_a,
            triangle_b,
            shared
          )
          refute legacy_allowed?(triangle_a, triangle_b, [shared])
        end

        def test_collinear_rays_overlapping_beyond_shared_vertex_fall_back
          shared = point(0, 0)
          triangle_a = [shared, point(4, 0), point(0, 4)]
          triangle_b = [shared, point(2, 0), point(2, -3)]

          assert_nil @normalizer.send(
            :coplanar_shared_vertex_intersection_decision_v2,
            triangle_a,
            triangle_b,
            shared
          )
          refute legacy_allowed?(triangle_a, triangle_b, [shared])
        end

        def test_fast_decisions_match_rational_reference_on_small_integer_grid
          triangles = integer_grid_triangles(-1..1)
          checked = 0
          fast_allowed = 0
          reference_allowed = 0

          triangles.combination(2) do |triangle_a, triangle_b|
            shared = triangle_a & triangle_b
            next unless shared.length <= 1

            reference = legacy_allowed?(triangle_a, triangle_b, shared)
            decision = if shared.empty?
                         @normalizer.send(
                           :coplanar_disjoint_intersection_decision_v2,
                           triangle_a,
                           triangle_b
                         )
                       else
                         @normalizer.send(
                           :coplanar_shared_vertex_intersection_decision_v2,
                           triangle_a,
                           triangle_b,
                           shared.first
                         )
                       end

            if reference
              assert_equal true, decision
            else
              assert_nil decision
            end
            checked += 1
            fast_allowed += 1 if decision
            reference_allowed += 1 if reference
          end

          assert_operator checked, :>, 1_000
          assert_operator reference_allowed, :>, 0
          assert_equal reference_allowed, fast_allowed
        end

        private

        def legacy_allowed?(triangle_a, triangle_b, shared)
          method = @normalizer.method(
            :coplanar_triangle_intersection_allowed?
          )
          method = method.super_method until
            method.nil? || method.owner == LocalVertexNormalizer
          raise 'Legacy coplanar predicate was not found' unless method

          method.call(triangle_a, triangle_b, shared)
        end

        def integer_grid_triangles(range)
          points = range.to_a.product(range.to_a).map do |x, y|
            point(x, y)
          end
          points.combination(3).filter_map do |points_for_triangle|
            orientation = @normalizer.send(
              :integer_orientation_2d,
              *points_for_triangle.map { |point_3d| point_3d.first(2) }
            )
            next if orientation.zero?

            orientation.positive? ?
              points_for_triangle :
              [
                points_for_triangle[0],
                points_for_triangle[2],
                points_for_triangle[1]
              ]
          end
        end

        def triangle(point_a, point_b, point_c)
          points = [point(*point_a), point(*point_b), point(*point_c)]
          orientation = @normalizer.send(
            :integer_orientation_2d,
            *points.map { |point_3d| point_3d.first(2) }
          )
          orientation.positive? ? points : [points[0], points[2], points[1]]
        end

        def point(x, y)
          [x, y, 0]
        end
      end
    end
  end
end
