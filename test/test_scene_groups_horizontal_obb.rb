# frozen_string_literal: true

require 'minitest/autorun'

class Numeric
  def mm
    self
  end unless method_defined?(:mm)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/scene_groups'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class SceneGroupsHorizontalObbTest < Minitest::Test
        Point = Struct.new(:x, :y, :z)

        def setup
          @subject = IndoorModel.allocate
          @subject.extend(IndoorModel::SceneGroups)
        end

        def test_horizontal_obb_uses_rotated_long_axis_and_world_horizontal_plane
          angle = 27.0 * Math::PI / 180.0
          points = rectangle_points(width: 10.0, height: 4.0, angle: angle)
          points << Point.new(points.first.x, points.first.y, 500.0)

          result = @subject.send(:horizontal_obb_axes, points)

          refute_nil result
          assert_in_delta 10.0, result[:extents][0], 1.0e-9
          assert_in_delta 4.0, result[:extents][1], 1.0e-9
          assert_in_delta angle, result[:angle], 1.0e-9
          assert_equal 0.0, result[:x][2]
          assert_equal 0.0, result[:y][2]
          assert_in_delta 0.0, dot(result[:x], result[:y]), 1.0e-12
          assert_in_delta 1.0, vector_length(result[:x]), 1.0e-12
          assert_in_delta 1.0, vector_length(result[:y]), 1.0e-12
        end

        def test_horizontal_obb_prefers_long_axis_when_hull_edge_starts_on_short_side
          angle = -38.0 * Math::PI / 180.0
          points = rectangle_points(width: 3.0, height: 12.0, angle: angle)

          result = @subject.send(:horizontal_obb_axes, points)

          refute_nil result
          assert_in_delta 12.0, result[:extents][0], 1.0e-9
          assert_in_delta 3.0, result[:extents][1], 1.0e-9
          assert_operator result[:x][0], :>=, 0.0
          assert_in_delta 0.0, dot(result[:x], result[:y]), 1.0e-12
        end

        private

        def rectangle_points(width:, height:, angle:)
          cosine = Math.cos(angle)
          sine = Math.sin(angle)
          [
            [0.0, 0.0],
            [width, 0.0],
            [width, height],
            [0.0, height]
          ].map do |x, y|
            Point.new(
              (x * cosine) - (y * sine) + 100.0,
              (x * sine) + (y * cosine) - 50.0,
              7.0
            )
          end
        end

        def dot(first, second)
          first.zip(second).sum { |a, b| a * b }
        end

        def vector_length(vector)
          Math.sqrt(dot(vector, vector))
        end
      end
    end
  end
end
