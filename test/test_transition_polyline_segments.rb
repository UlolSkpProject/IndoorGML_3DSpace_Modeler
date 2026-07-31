# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/ui/overlays/builders/transition_curve_builder'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TransitionPolylineSegmentsTest < Minitest::Test
        def setup
          @builder = TransitionCurveBuilder.allocate
        end

        def test_empty_points_return_empty_segments
          assert_equal [], @builder.polyline_segments([])
        end

        def test_single_point_returns_empty_segments
          point = Object.new

          assert_equal [], @builder.polyline_segments([point])
        end

        def test_two_points_preserve_original_references
          first = Object.new
          second = Object.new

          result = @builder.polyline_segments([first, second])

          assert_equal [first, second], result
          assert_same first, result[0]
          assert_same second, result[1]
        end

        def test_multiple_points_match_each_cons_flat_map_order
          points = Array.new(8) { Object.new }
          expected = points.each_cons(2).flat_map { |from, to| [from, to] }

          result = @builder.polyline_segments(points)

          assert_equal expected, result
          expected.each_with_index do |point, index|
            assert_same point, result[index]
          end
        end
      end
    end
  end
end
