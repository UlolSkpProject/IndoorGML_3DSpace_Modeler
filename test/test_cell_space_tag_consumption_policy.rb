# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLifecycleContext
        attr_reader :calls

        def initialize
          @calls = []
        end

        def default_storey_name
          'F01'
        end

        def initialize_scene(cell_space, storey: default_storey_name)
          @calls << [:initialize_scene, cell_space, storey]
          true
        end
      end
    end
  end
end

require_relative '../indoor3d/application/cell_space_behavior_policies'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceTagConsumptionPolicyTest < Minitest::Test
        Policy = CellSpaceAutoConversionPolicy

        Tag = Struct.new(:name)

        class Layers
          def initialize(untagged)
            @untagged = untagged
          end

          def [](key)
            return @untagged if key == 0
            return @untagged if %w[Untagged Layer0].include?(key)

            nil
          end
        end

        class Model
          attr_reader :layers

          def initialize(untagged: Tag.new('Untagged'))
            @layers = Layers.new(untagged)
          end
        end

        class Entity
          attr_reader :layer_assignments, :children
          attr_accessor :layer

          def initialize(layer:, model:, children: [])
            @layer = layer
            @model = model
            @children = children
            @attributes = {}
            @layer_assignments = 0
          end

          def valid?
            true
          end

          def model
            @model
          end

          def layer=(value)
            @layer_assignments += 1
            @layer = value
          end

          def get_attribute(dictionary, key, default = nil)
            @attributes.fetch([dictionary, key], default)
          end

          def set_attribute(dictionary, key, value)
            @attributes[[dictionary, key]] = value
          end

          def delete_attribute(dictionary, key)
            @attributes.delete([dictionary, key])
          end
        end

        CellSpace = Struct.new(:sketchup_group)

        def test_create_scene_consumes_only_outer_group_tag
          model = Model.new
          nested = Entity.new(layer: Tag.new('F01F01_RM_DR'), model: model)
          outer = Entity.new(
            layer: Tag.new('F01F01_IP_RM_23'),
            model: model,
            children: [nested]
          )
          outer.set_attribute(
            Policy::DICTIONARY_NAME,
            Policy::AUTO_CONVERSION_DISABLED_KEY,
            true
          )
          cell_space = CellSpace.new(outer)
          context = CellSpaceLifecycleContext.new

          assert context.initialize_scene(cell_space, storey: 'F01')

          assert_equal 'Untagged', outer.layer.name
          assert_equal 1, outer.layer_assignments
          assert_equal 'F01F01_RM_DR', nested.layer.name
          refute Policy.disabled?(outer)
          assert_equal [[:initialize_scene, cell_space, 'F01']], context.calls
        end

        def test_already_untagged_group_does_not_write_layer_again
          model = Model.new
          outer = Entity.new(layer: model.layers[0], model: model)
          context = CellSpaceLifecycleContext.new

          assert context.initialize_scene(CellSpace.new(outer), storey: 'B01')

          assert_equal 0, outer.layer_assignments
          assert_equal 'Untagged', outer.layer.name
        end

        def test_tag_consumption_failure_aborts_before_base_scene_initialization
          outer = Entity.new(
            layer: Tag.new('F01F01_IP_RM_23'),
            model: Object.new
          )
          context = CellSpaceLifecycleContext.new

          error = assert_raises(RuntimeError) do
            context.initialize_scene(CellSpace.new(outer), storey: 'F01')
          end

          assert_equal 'CellSpace Tag could not be moved to Untagged', error.message
          assert_empty context.calls
          assert_equal 'F01F01_IP_RM_23', outer.layer.name
        end
      end
    end
  end
end
