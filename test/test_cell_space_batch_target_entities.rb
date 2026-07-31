# frozen_string_literal: true

require 'matrix'
require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Transformation; end
    end

    module IndoorCore
      class IndoorModel; end unless const_defined?(:IndoorModel, false)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_batch_execution'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceBatchTargetEntitiesTest < Minitest::Test
        EPSILON = 1.0e-10

        def setup
          transformation = Utils::Transformation
          @original_root_transformation_in_model =
            transformation.method(:root_transformation_in_model) if
              transformation.respond_to?(:root_transformation_in_model)
          transformation.define_singleton_method(:root_transformation_in_model) do |root_group|
            root_group.world_transformation
          end
        end

        def teardown
          transformation = Utils::Transformation
          if @original_root_transformation_in_model
            original = @original_root_transformation_in_model
            transformation.define_singleton_method(:root_transformation_in_model) do |*args|
              original.call(*args)
            end
          else
            singleton_class = class << transformation; self; end
            singleton_class.send(:remove_method, :root_transformation_in_model) if
              singleton_class.method_defined?(:root_transformation_in_model)
          end
        end

        def test_primal_local_transform_preserves_world_transform
          primal_world = TestTransformation.translation(120.0, -35.0, 18.0) *
                         TestTransformation.rotation_z(0.37)
          source_world = TestTransformation.translation(-42.0, 215.0, 73.0) *
                         TestTransformation.rotation_z(-0.61) *
                         TestTransformation.scale(1.25, 0.8, 1.5)
          primal = FakePrimalGroup.new(primal_world)

          local = CellSpaceBatchTargetEntities.primal_local_transformation(
            primal,
            source_world
          )

          assert_transformation_close(source_world, primal_world * local)
        end

        def test_add_instance_uses_primal_local_transform_and_returns_unique_group
          primal_world = TestTransformation.translation(10.0, 20.0, 30.0) *
                         TestTransformation.rotation_z(0.5)
          source_world = TestTransformation.translation(100.0, -50.0, 7.0) *
                         TestTransformation.rotation_z(-0.2)
          entities = FakeEntities.new
          primal = FakePrimalGroup.new(primal_world, entities: entities)
          target = CellSpaceBatchTargetEntities.new(
            primal_group_resolver: proc { primal }
          )

          result = target.add_instance(:definition, source_world)

          expected_local = primal_world.inverse * source_world
          assert_equal :definition, entities.received_definition
          assert_transformation_close(expected_local, entities.received_transformation)
          assert_same entities.group, result
          assert_equal 1, entities.instance.to_group_calls
          assert_equal 1, entities.group.make_unique_calls
        end

        def test_add_instance_erases_partial_copy_when_group_conversion_fails
          entities = FakeEntities.new(to_group_error: RuntimeError.new('to_group failed'))
          primal = FakePrimalGroup.new(TestTransformation.identity, entities: entities)
          target = CellSpaceBatchTargetEntities.new(
            primal_group_resolver: proc { primal }
          )

          error = assert_raises(RuntimeError) do
            target.add_instance(:definition, TestTransformation.identity)
          end

          assert_equal 'to_group failed', error.message
          assert entities.instance.erased?
        end

        def test_add_instance_rejects_missing_primal_group_before_copy
          target = CellSpaceBatchTargetEntities.new(
            primal_group_resolver: proc { nil }
          )

          error = assert_raises(ArgumentError) do
            target.add_instance(:definition, TestTransformation.identity)
          end

          assert_match(/PrimalSpaceFeatures is not ready/, error.message)
        end

        private

        def assert_transformation_close(expected, actual)
          expected.values.zip(actual.values).each_with_index do |(expected_value, actual_value), index|
            assert_in_delta expected_value, actual_value, EPSILON, "matrix value #{index}"
          end
        end

        class TestTransformation
          attr_reader :matrix

          def initialize(matrix)
            @matrix = matrix
          end

          def self.identity
            new(Matrix.identity(4))
          end

          def self.translation(x, y, z)
            new(
              Matrix[
                [1.0, 0.0, 0.0, x],
                [0.0, 1.0, 0.0, y],
                [0.0, 0.0, 1.0, z],
                [0.0, 0.0, 0.0, 1.0]
              ]
            )
          end

          def self.rotation_z(angle)
            cosine = Math.cos(angle)
            sine = Math.sin(angle)
            new(
              Matrix[
                [cosine, -sine, 0.0, 0.0],
                [sine, cosine, 0.0, 0.0],
                [0.0, 0.0, 1.0, 0.0],
                [0.0, 0.0, 0.0, 1.0]
              ]
            )
          end

          def self.scale(x, y, z)
            new(
              Matrix[
                [x, 0.0, 0.0, 0.0],
                [0.0, y, 0.0, 0.0],
                [0.0, 0.0, z, 0.0],
                [0.0, 0.0, 0.0, 1.0]
              ]
            )
          end

          def *(other)
            self.class.new(matrix * other.matrix)
          end

          def inverse
            self.class.new(matrix.inverse)
          end

          def values
            matrix.to_a.flatten
          end
        end

        class FakePrimalGroup
          attr_reader :world_transformation, :entities

          def initialize(world_transformation, entities: FakeEntities.new)
            @world_transformation = world_transformation
            @entities = entities
          end

          def valid?
            true
          end
        end

        class FakeEntities
          attr_reader :received_definition, :received_transformation, :instance, :group

          def initialize(to_group_error: nil)
            @group = FakeGroup.new
            @instance = FakeInstance.new(@group, to_group_error: to_group_error)
          end

          def add_instance(definition, transformation)
            @received_definition = definition
            @received_transformation = transformation
            @instance
          end
        end

        class FakeInstance
          attr_reader :to_group_calls

          def initialize(group, to_group_error: nil)
            @group = group
            @to_group_error = to_group_error
            @to_group_calls = 0
            @erased = false
          end

          def valid?
            !@erased
          end

          def to_group
            @to_group_calls += 1
            raise @to_group_error if @to_group_error

            @group
          end

          def erase!
            @erased = true
          end

          def erased?
            @erased
          end
        end

        class FakeGroup
          attr_reader :make_unique_calls

          def initialize
            @make_unique_calls = 0
          end

          def valid?
            true
          end

          def make_unique
            @make_unique_calls += 1
            self
          end
        end
      end
    end
  end
end
