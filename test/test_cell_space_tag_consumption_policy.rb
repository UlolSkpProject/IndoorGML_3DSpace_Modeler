# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/cell_space_auto_conversion_policy'

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

        def test_consumes_only_outer_group_tag
          model = Model.new
          nested = Entity.new(layer: Tag.new('F01F01_RM_DR'), model: model)
          outer = Entity.new(
            layer: Tag.new('F01F01_IP_RM_23'),
            model: model,
            children: [nested]
          )

          assert Policy.consume_tag!(outer)

          assert_equal 'Untagged', outer.layer.name
          assert_equal 1, outer.layer_assignments
          assert_equal 'F01F01_RM_DR', nested.layer.name
        end

        def test_already_untagged_group_does_not_write_layer_again
          model = Model.new
          outer = Entity.new(layer: model.layers[0], model: model)

          assert Policy.consume_tag!(outer)

          assert_equal 0, outer.layer_assignments
          assert_equal 'Untagged', outer.layer.name
        end

        def test_missing_untagged_tag_returns_false_without_mutation
          outer = Entity.new(
            layer: Tag.new('F01F01_IP_RM_23'),
            model: Object.new
          )

          refute Policy.consume_tag!(outer)

          assert_equal 0, outer.layer_assignments
          assert_equal 'F01F01_IP_RM_23', outer.layer.name
        end

        def test_legacy_marker_can_be_cleared_after_tag_consumption
          model = Model.new
          outer = Entity.new(
            layer: Tag.new('F01F01_IP_RM_23'),
            model: model
          )
          assert Policy.disable!(outer)

          assert Policy.consume_tag!(outer)
          assert Policy.enable!(outer)

          refute Policy.disabled?(outer)
          assert_equal 'Untagged', outer.layer.name
        end
      end
    end
  end
end
