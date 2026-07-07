# frozen_string_literal: true

require 'minitest/autorun'

module Geom
  unless const_defined?(:Transformation, false)
    class Transformation
      IDENTITY = [
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
      ].freeze

      def initialize(values = nil)
        @values = (values || IDENTITY).map(&:to_f)
      end

      def to_a
        @values.dup
      end

      def *(other)
        a = @values
        b = other.to_a
        result = Array.new(16, 0.0)
        4.times do |row|
          4.times do |column|
            result[row + (column * 4)] = (0...4).sum do |index|
              a[row + (index * 4)] * b[index + (column * 4)]
            end
          end
        end
        self.class.new(result)
      end

      def inverse
        values = @values
        self.class.new(
          [
            1.0 / values[0], 0.0, 0.0, 0.0,
            0.0, 1.0 / values[5], 0.0, 0.0,
            0.0, 0.0, 1.0 / values[10], 0.0,
            -values[12] / values[0], -values[13] / values[5], -values[14] / values[10], 1.0
          ]
        )
      end
    end
  end
end

require_relative '../indoor3d/utils/transformation'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      class TransformationScaleTest < Minitest::Test
        def test_identity_transform_is_not_scaled
          transformation = Geom::Transformation.new

          refute Transformation.scaled?(transformation)
        end

        def test_mirror_transform_is_scaled
          transformation = Geom::Transformation.new(
            [
              -1.0, 0.0, 0.0, 0.0,
              0.0, 1.0, 0.0, 0.0,
              0.0, 0.0, 1.0, 0.0,
              0.0, 0.0, 0.0, 1.0
            ]
          )

          assert Transformation.scaled?(transformation)
        end

        def test_unit_length_shear_transform_is_scaled
          shear = 0.6
          normalized_y = ::Math.sqrt(1.0 - (shear * shear))
          transformation = Geom::Transformation.new(
            [
              1.0, 0.0, 0.0, 0.0,
              shear, normalized_y, 0.0, 0.0,
              0.0, 0.0, 1.0, 0.0,
              0.0, 0.0, 0.0, 1.0
            ]
          )

          assert Transformation.scaled?(transformation)
        end

        def test_unscaled_values_preserve_origin_and_normalize_axes
          values = [
            2.0, 0.0, 0.0, 0.0,
            0.0, 3.0, 0.0, 0.0,
            0.0, 0.0, 4.0, 0.0,
            10.0, 20.0, 30.0, 1.0
          ]

          normalized = Transformation.unscaled_values(values)

          assert_equal [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            10.0, 20.0, 30.0, 1.0
          ], normalized
        end

        def test_unscaled_values_orthogonalize_unit_length_shear
          shear = 0.6
          normalized_y = ::Math.sqrt(1.0 - (shear * shear))
          values = [
            1.0, 0.0, 0.0, 0.0,
            shear, normalized_y, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            10.0, 20.0, 30.0, 1.0
          ]

          normalized = Transformation.unscaled_values(values)

          assert_in_delta 1.0, normalized[0], 0.000001
          assert_in_delta 0.0, normalized[1], 0.000001
          assert_in_delta 0.0, normalized[2], 0.000001
          assert_in_delta 0.0, normalized[4], 0.000001
          assert_in_delta 1.0, normalized[5], 0.000001
          assert_in_delta 0.0, normalized[6], 0.000001
          assert_in_delta 0.0, normalized[8], 0.000001
          assert_in_delta 0.0, normalized[9], 0.000001
          assert_in_delta 1.0, normalized[10], 0.000001
          assert_equal [10.0, 20.0, 30.0, 1.0], normalized[12, 4]
        end

        def test_scale_bake_transform_moves_scale_into_local_geometry_space
          transformation = Geom::Transformation.new(
            [
              2.0, 0.0, 0.0, 0.0,
              0.0, 3.0, 0.0, 0.0,
              0.0, 0.0, 4.0, 0.0,
              10.0, 20.0, 30.0, 1.0
            ]
          )

          bake = Transformation.scale_bake_transform(transformation)

          assert_equal [
            2.0, 0.0, 0.0, 0.0,
            0.0, 3.0, 0.0, 0.0,
            0.0, 0.0, 4.0, 0.0,
            0.0, 0.0, 0.0, 1.0
          ], bake.to_a
        end
      end
    end
  end
end
