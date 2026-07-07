# frozen_string_literal: true

require 'minitest/autorun'

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def -(other)
      Vector3d.new(x - other.x, y - other.y, z - other.z)
    end
  end unless const_defined?(:Point3d, false)

  class Point3d
    def distance(other)
      Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    end unless method_defined?(:distance)

    def -(other)
      Vector3d.new(x - other.x, y - other.y, z - other.z)
    end unless method_defined?(:-)
  end

  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def normalize!
      length = Math.sqrt((x * x) + (y * y) + (z * z))
      return self if length <= 0.0

      @x /= length
      @y /= length
      @z /= length
      self
    end

    def dot(other)
      (x * other.x) + (y * other.y) + (z * other.z)
    end
  end unless const_defined?(:Vector3d, false)

  class Vector3d
    def length
      Math.sqrt((x * x) + (y * y) + (z * z))
    end unless method_defined?(:length)

    def normalize!
      length = self.length
      return self if length <= 0.0

      @x /= length
      @y /= length
      @z /= length
      self
    end unless method_defined?(:normalize!)

    def dot(other)
      (x * other.x) + (y * other.y) + (z * other.z)
    end unless method_defined?(:dot)
  end
end

require_relative '../indoor3d/utils/hermite_spline'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Math
        class HermiteSplineTest < Minitest::Test
          HermiteSpline = ULOL::Indoor3DGmlModeler::Utils::Math::HermiteSpline

          def setup
            @original_bend_factor = HermiteSpline.method(:bend_factor)
          end

          def teardown
            original = @original_bend_factor
            HermiteSpline.define_singleton_method(:bend_factor) do |pa, pb, pc|
              original.call(pa, pb, pc)
            end
          end

          def test_refinement_skips_bend_factor_for_first_interval
            calls = []
            HermiteSpline.define_singleton_method(:bend_factor) do |pa, pb, pc|
              calls << [pa, pb, pc]
              0.0
            end

            HermiteSpline.generate_segment(
              point(0, 0, 0),
              point(3, 0, 0),
              vector(0, 0, 0),
              vector(0, 0, 0),
              3,
              refine: true
            )

            base_points = base_points(3)
            assert_equal 2, calls.length
            assert_point_equal base_points[0], calls[0][0]
            assert_point_equal base_points[1], calls[0][1]
            assert_point_equal base_points[2], calls[0][2]
            assert_point_equal base_points[1], calls[1][0]
            assert_point_equal base_points[2], calls[1][1]
            assert_point_equal base_points[3], calls[1][2]
          end

          def test_refinement_does_not_swallow_later_bend_factor_errors
            HermiteSpline.define_singleton_method(:bend_factor) do |_pa, _pb, _pc|
              raise 'bend failed'
            end

            assert_raises(RuntimeError) do
              HermiteSpline.generate_segment(
                point(0, 0, 0),
                point(3, 0, 0),
                vector(0, 0, 0),
                vector(0, 0, 0),
                2,
                refine: true
              )
            end
          end

          def test_unrefined_path_preserves_uniform_samples_and_include_start
            with_start = HermiteSpline.generate_segment(
              point(0, 0, 0),
              point(3, 0, 0),
              vector(0, 0, 0),
              vector(0, 0, 0),
              3,
              include_start: true,
              refine: false
            )
            without_start = HermiteSpline.generate_segment(
              point(0, 0, 0),
              point(3, 0, 0),
              vector(0, 0, 0),
              vector(0, 0, 0),
              3,
              include_start: false,
              refine: false
            )

            assert_equal 4, with_start.length
            assert_equal 3, without_start.length
            assert_point_equal with_start[1], without_start[0]
          end

          private

          def base_points(segments)
            (0..segments).map do |i|
              HermiteSpline.point(
                point(0, 0, 0),
                point(3, 0, 0),
                vector(0, 0, 0),
                vector(0, 0, 0),
                i.to_f / segments
              )
            end
          end

          def point(x, y, z)
            Geom::Point3d.new(x, y, z)
          end

          def vector(x, y, z)
            Geom::Vector3d.new(x, y, z)
          end

          def assert_point_equal(expected, actual)
            assert_in_delta expected.x, actual.x, 0.000001
            assert_in_delta expected.y, actual.y, 0.000001
            assert_in_delta expected.z, actual.z, 0.000001
          end
        end
      end
    end
  end
end
