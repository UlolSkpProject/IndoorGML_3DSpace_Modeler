# frozen_string_literal: true

require 'minitest/autorun'

unless defined?(Sketchup::Group)
  module Sketchup
    class Group; end
  end
end

require_relative '../indoor3d/infrastructure/scene/entity_copy_helper'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EntityCopyHelperTest < Minitest::Test
        def test_copy_instance_converts_and_makes_unique_for_source_group
          source = FakeGroup.new(name: 'Room', material: 'mat', layer: 'layer', visible: false)
          target_entities = FakeEntities.new
          copied_attributes = nil

          copy = EntityCopyHelper.copy_instance(
            source: source,
            target_entities: target_entities,
            transformation: :transform,
            convert_to_group: :source_group,
            make_unique: :source_group,
            copy_attributes: [:name, :material, :layer, :visible],
            attribute_copier: proc { |src, dst| copied_attributes = [src, dst] }
          )

          assert_same source.definition, target_entities.added_definition
          assert_equal :transform, target_entities.added_transformation
          assert_equal true, copy.to_group_called
          assert_equal true, copy.make_unique_called
          assert_equal 'Room', copy.name
          assert_equal 'mat', copy.material
          assert_equal 'layer', copy.layer
          assert_equal false, copy.visible?
          assert_equal [source, copy], copied_attributes
        end

        def test_source_group_option_does_not_convert_component_instance
          source = FakeComponentInstance.new
          copy = EntityCopyHelper.copy_instance(
            source: source,
            target_entities: FakeEntities.new,
            transformation: :transform,
            convert_to_group: :source_group,
            make_unique: :source_group
          )

          assert_equal false, copy.to_group_called
          assert_equal false, copy.make_unique_called
        end

        def test_true_option_converts_any_supported_copy
          source = FakeComponentInstance.new
          copy = EntityCopyHelper.copy_instance(
            source: source,
            target_entities: FakeEntities.new,
            transformation: :transform,
            convert_to_group: true,
            make_unique: true
          )

          assert_equal true, copy.to_group_called
          assert_equal true, copy.make_unique_called
        end

        def test_invalid_source_raises_argument_error
          error = assert_raises(ArgumentError) do
            EntityCopyHelper.copy_instance(
              source: Object.new,
              target_entities: FakeEntities.new,
              transformation: :transform
            )
          end

          assert_match(/Unsupported entity copy source/, error.message)
        end

        class FakeDefinition
          def valid?
            true
          end
        end

        class FakeCopy
          attr_accessor :name, :material, :layer
          attr_reader :to_group_called, :make_unique_called

          def initialize
            @visible = true
            @to_group_called = false
            @make_unique_called = false
          end

          def valid?
            true
          end

          def to_group
            @to_group_called = true
            self
          end

          def make_unique
            @make_unique_called = true
          end

          def visible=(value)
            @visible = value == true
          end

          def visible?
            @visible == true
          end
        end

        class FakeEntities
          attr_reader :added_definition, :added_transformation

          def add_instance(definition, transformation)
            @added_definition = definition
            @added_transformation = transformation
            FakeCopy.new
          end
        end

        class FakeSource
          attr_reader :definition, :name, :material, :layer

          def initialize(name: 'source', material: nil, layer: nil, visible: true)
            @definition = FakeDefinition.new
            @name = name
            @material = material
            @layer = layer
            @visible = visible
          end

          def valid?
            true
          end

          def visible?
            @visible == true
          end
        end

        class FakeGroup < Sketchup::Group
          attr_reader :definition, :name, :material, :layer

          def initialize(name: 'source', material: nil, layer: nil, visible: true)
            @definition = FakeDefinition.new
            @name = name
            @material = material
            @layer = layer
            @visible = visible
          end

          def valid?
            true
          end

          def visible?
            @visible == true
          end
        end

        class FakeComponentInstance < FakeSource; end
      end
    end
  end
end
