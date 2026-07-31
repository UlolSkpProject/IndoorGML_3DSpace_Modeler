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

  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def length
      Math.sqrt((x * x) + (y * y) + (z * z))
    end

    def normalize!
      len = length
      return self if len <= 0.0

      @x /= len
      @y /= len
      @z /= len
      self
    end

    def dot(other)
      (x * other.x) + (y * other.y) + (z * other.z)
    end
  end unless const_defined?(:Vector3d, false)
end

require_relative '../indoor3d/utils/hermite_spline'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Math
        class HermiteSplineGenerationEquivalenceTest < Minitest::Test
          HermiteSpline = ULOL::Indoor3DGmlModeler::Utils::Math::HermiteSpline

          CASES = [
            [
              Geom::Point3d.new(0, 0, 0),
              Geom::Point3d.new(10, 5, 2),
              Geom::Vector3d.new(12, 0, 0),
              Geom::Vector3d.new(0, 8, 1)
            ],
            [
              Geom::Point3d.new(-4, 3, 8),
              Geom::Point3d.new(7, -2, 1),
              Geom::Vector3d.new(3, 9, -2),
              Geom::Vector3d.new(-6, 2, 5)
            ],
            [
              Geom::Point3d.new(1, 1, 1),
              Geom::Point3d.new(9, 1, 1),
              Geom::Vector3d.new(8, 0, 0),
              Geom::Vector3d.new(8, 0, 0)
            ]
          ].freeze

          SEGMENT_COUNTS = [1, 2, 3, 6, 9].freeze

          def test_refined_generation_matches_legacy_coordinates_and_order
            CASES.each do |p0, p1, tangent0, tangent1|
              SEGMENT_COUNTS.each do |segments|
                [true, false].each do |include_start|
                  expected = legacy_generate_segment(
                    p0, p1, tangent0, tangent1, segments,
                    include_start: include_start,
                    refine: true
                  )
                  actual = HermiteSpline.generate_segment(
                    p0, p1, tangent0, tangent1, segments,
                    include_start: include_start,
                    refine: true
                  )

                  assert_equal expected.length, actual.length
                  expected.zip(actual).each do |expected_point, actual_point|
                    assert_equal expected_point.x, actual_point.x
                    assert_equal expected_point.y, actual_point.y
                    assert_equal expected_point.z, actual_point.z
                  end
                end
              end
            end
          end

          def test_unrefined_generation_still_matches_legacy_path
            p0, p1, tangent0, tangent1 = CASES.first
            SEGMENT_COUNTS.each do |segments|
              [true, false].each do |include_start|
                expected = legacy_generate_segment(
                  p0, p1, tangent0, tangent1, segments,
                  include_start: include_start,
                  refine: false
                )
                actual = HermiteSpline.generate_segment(
                  p0, p1, tangent0, tangent1, segments,
                  include_start: include_start,
                  refine: false
                )

                assert_equal expected.length, actual.length
                expected.zip(actual).each do |expected_point, actual_point|
                  assert_equal expected_point.x, actual_point.x
                  assert_equal expected_point.y, actual_point.y
                  assert_equal expected_point.z, actual_point.z
                end
              end
            end
          end

          private

          def legacy_generate_segment(p0, p1, tangent0, tangent1, segments, include_start:, refine:)
            base_ts = (0..segments).map { |i| i.to_f / segments }
            unless refine
              start_index = include_start ? 0 : 1
              return base_ts[start_index..-1].map do |t|
                HermiteSpline.point(p0, p1, tangent0, tangent1, t)
              end
            end

            points = base_ts.map { |t| HermiteSpline.point(p0, p1, tangent0, tangent1, t) }
            refined_ts = [base_ts.first]
            base_ts.each_cons(2).with_index do |(t_a, t_b), index|
              bend = index.zero? ? 0.0 : HermiteSpline.bend_factor(
                points[index - 1], points[index], points[index + 1]
              )
              extra = (bend * 3).round.clamp(0, 4)
              extra.times do |extra_index|
                refined_ts << t_a + ((t_b - t_a) * (extra_index + 1).to_f / (extra + 1))
              end
              refined_ts << t_b
            end

            start_index = include_start ? 0 : 1
            refined_ts.uniq.sort[start_index..-1].map do |t|
              HermiteSpline.point(p0, p1, tangent0, tangent1, t)
            end
          end
        end
      end
    end
  end
end
