# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/utils/geometry'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      class GeometryPolygon2dTest < Minitest::Test
        def test_point_in_polygon_2d_matches_boundary_and_interior_cases
          polygon = [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]]

          assert Geometry.point_in_polygon_2d?([5.0, 5.0], polygon, 0.001)
          assert Geometry.point_in_polygon_2d?([0.0, 5.0], polygon, 0.001)
          refute Geometry.point_in_polygon_2d?([11.0, 5.0], polygon, 0.001)
        end

        def test_intersect_polygons_2d_and_area_value
          subject = [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]]
          clipping = [[2.0, 2.0], [6.0, 2.0], [6.0, 6.0], [2.0, 6.0]]

          overlap = Geometry.intersect_polygons_2d(subject, clipping)

          assert_operator overlap.length, :>=, 3
          assert_in_delta 4.0, Geometry.polygon_area_2d_value(overlap).abs, 0.000001
        end
      end
    end
  end
end
