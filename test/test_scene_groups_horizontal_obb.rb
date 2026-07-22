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

        def test_dominant_wall_normal_uses_face_count_before_area
          samples = [
            wall_sample([1, 0, 0], 2.0),
            wall_sample([-1, 0, 0], 3.0),
            wall_sample([1, 0.001, 0], 1.0),
            wall_sample([0, 1, 0], 1_000.0),
            wall_sample([0, -1, 0], 1_000.0)
          ]

          result = dominant_wall_axes(samples)

          assert_equal 3, result[:count]
          assert_operator result[:x][0], :>, 0.999
          assert_in_delta 0.0, result[:x][2], 1.0e-12
          assert_right_handed(result)
        end

        def test_connected_coplanar_face_subdivision_counts_as_one_wall_patch
          subdivided_wall = 10.times.map do
            wall_sample([1, 0, 0], 10.0, patch: :subdivided_wall)
          end
          separate_walls = [
            wall_sample([0, 1, 0], 10.0, patch: :first_wall),
            wall_sample([0, -1, 0], 10.0, patch: :second_wall)
          ]

          result = dominant_wall_axes(subdivided_wall + separate_walls)

          assert_equal 2, result[:count]
          assert_equal 2, result[:face_count]
          assert_operator result[:x][1], :>, 0.999
        end

        def test_dominant_wall_normal_tie_uses_largest_world_face
          samples = [
            wall_sample([1, 0, 0], 10.0),
            wall_sample([-1, 0, 0], 12.0),
            wall_sample([0, 1, 0], 11.0),
            wall_sample([0, -1, 0], 50.0)
          ]

          result = dominant_wall_axes(samples)

          assert_equal 2, result[:count]
          assert_operator result[:x][1], :>, 0.999
          assert_right_handed(result)
        end

        def test_dominant_wall_normal_complete_tie_is_order_independent
          samples = [
            wall_sample([1, 0, 0], 10.0),
            wall_sample([-1, 0, 0], 10.0),
            wall_sample([0, 1, 0], 10.0),
            wall_sample([0, -1, 0], 10.0)
          ]

          expected = dominant_wall_axes(samples)
          10.times do |seed|
            actual = dominant_wall_axes(samples.shuffle(random: Random.new(seed)))
            assert_in_delta expected[:x][0], actual[:x][0], 1.0e-12
            assert_in_delta expected[:x][1], actual[:x][1], 1.0e-12
          end
          assert_operator expected[:x][0], :>, 0.999
        end

        def test_dominant_wall_normal_clusters_opposite_noisy_rotated_normals
          angle = 27.0 * Math::PI / 180.0
          normal = [Math.cos(angle), Math.sin(angle), 0.0]
          opposite = normal.map { |component| -component }
          noisy_angle = angle + (0.2 * Math::PI / 180.0)
          samples = [
            wall_sample(normal, 10.0),
            wall_sample(opposite, 10.0),
            wall_sample([Math.cos(noisy_angle), Math.sin(noisy_angle), 0.001], 10.0)
          ]

          result = dominant_wall_axes(samples)

          assert_equal 3, result[:count]
          assert_in_delta angle + (0.2 / 3.0 * Math::PI / 180.0), result[:angle], 1.0e-8
          assert_right_handed(result)
        end

        def test_dominant_wall_normal_rejects_horizontal_and_steep_faces
          samples = [
            wall_sample([0, 0, 1], 100.0),
            wall_sample([1, 0, 0.1], 100.0)
          ]

          assert_nil dominant_wall_axes(samples)
        end

        def test_world_face_normal_applies_instance_rotation_and_scale
          angle = 31.0 * Math::PI / 180.0
          transformation = FakeWorldTransformation.new(angle, 2.0, 0.5, 3.0)
          face = FakeWorldFace.new([
            Point.new(0, 0, 0),
            Point.new(0, 4, 0),
            Point.new(0, 4, 3),
            Point.new(0, 0, 3)
          ], 12.0)

          normal = @subject.send(:world_face_normal, face, transformation)
          result = dominant_wall_axes([{ normal: normal, area: face.area(transformation) }])

          assert_in_delta Math.cos(angle), result[:x][0], 1.0e-12
          assert_in_delta Math.sin(angle), result[:x][1], 1.0e-12
          assert_in_delta 18.0, result[:max_face_area], 1.0e-12
        end

        private

        FakeWorldVertex = Struct.new(:position)
        FakeWorldLoop = Struct.new(:vertices)

        class FakeWorldFace
          attr_reader :outer_loop

          def initialize(points, local_area)
            @outer_loop = FakeWorldLoop.new(
              points.map { |point| FakeWorldVertex.new(point) }
            )
            @local_area = local_area
          end

          def area(transformation = nil)
            return @local_area unless transformation

            @local_area * transformation.y_scale * transformation.z_scale
          end
        end

        class FakeWorldTransformation
          attr_reader :y_scale, :z_scale

          def initialize(angle, x_scale, y_scale, z_scale)
            @cosine = Math.cos(angle)
            @sine = Math.sin(angle)
            @x_scale = x_scale
            @y_scale = y_scale
            @z_scale = z_scale
          end

          def transform_point(point)
            x = point.x * @x_scale
            y = point.y * @y_scale
            Point.new(
              (x * @cosine) - (y * @sine),
              (x * @sine) + (y * @cosine),
              point.z * @z_scale
            )
          end
        end

        Point.define_method(:transform) do |transformation|
          transformation.transform_point(self)
        end

        def dominant_wall_axes(samples)
          @subject.send(:dominant_vertical_face_axes_from_samples, samples)
        end

        def wall_sample(normal, area, patch: nil)
          sample = { normal: normal, area: area }
          sample[:frequency_key] = patch if patch
          sample
        end

        def assert_right_handed(result)
          assert_in_delta 1.0, vector_length(result[:x]), 1.0e-12
          assert_in_delta 1.0, vector_length(result[:y]), 1.0e-12
          assert_in_delta 0.0, dot(result[:x], result[:y]), 1.0e-12
          cross_z = (result[:x][0] * result[:y][1]) -
            (result[:x][1] * result[:y][0])
          assert_in_delta 1.0, cross_z, 1.0e-12
        end

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
