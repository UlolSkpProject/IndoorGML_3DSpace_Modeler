# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  def self.active_model
    nil
  end
end

module Geom
  class Transformation
    attr_reader :origin, :inverse_calls, :multiply_calls

    def initialize(origin = :origin)
      @origin = origin
      @inverse_calls = 0
      @multiply_calls = 0
    end

    def inverse
      @inverse_calls += 1
      self
    end

    def *(other)
      @multiply_calls += 1
      other
    end
  end unless const_defined?(:Transformation)
end

require_relative '../indoor3d/utils/transformation'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      class TransformationRootFastPathTest < Minitest::Test
        FakeRoot = Struct.new(:definition, :transformation) do
          def valid?
            true
          end
        end

        FakeEntity = Struct.new(:parent, :transformation) do
          def valid?
            true
          end
        end

        def test_direct_child_returns_entity_transformation_without_root_round_trip
          root_transform = Geom::Transformation.new(:root)
          entity_transform = Geom::Transformation.new(:entity)
          definition = Object.new
          root = FakeRoot.new(definition, root_transform)
          entity = FakeEntity.new(definition, entity_transform)

          result = Transformation.entity_transformation_in_root(entity, root)

          assert_same entity_transform, result
          assert_equal 0, root_transform.inverse_calls
          assert_equal 0, root_transform.multiply_calls
        end

        def test_nested_entity_keeps_general_root_conversion_path
          root_transform = Geom::Transformation.new(:root)
          entity_transform = Geom::Transformation.new(:entity)
          root = FakeRoot.new(Object.new, root_transform)
          entity = FakeEntity.new(Object.new, entity_transform)

          result = Transformation.entity_transformation_in_root(entity, root)

          assert_same entity_transform, result
          assert_operator root_transform.inverse_calls, :>, 0
          assert_operator root_transform.multiply_calls, :>, 0
        end
      end
    end
  end
end
