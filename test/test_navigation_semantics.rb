# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'

module Sketchup
  class Group; end unless const_defined?(:Group, false)
end

require_relative '../indoor3d/domain/abstract_feature'
require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/domain/navigation_semantic'
require_relative '../indoor3d/domain/cell_space'
require_relative '../indoor3d/infrastructure/persistence/attribute_serializer'
require_relative '../indoor3d/export/gml_exporter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class NavigationSemanticTest < Minitest::Test
        FakeCellSpace = Struct.new(
          :id,
          :cell_type,
          :category_code,
          :navigation_class,
          :navigation_class_code_space,
          :navigation_function,
          :navigation_function_code_space,
          :navigation_usage,
          :navigation_usage_code_space,
          keyword_init: true
        )

        ANNEX_D_URI = 'urn:ogc:def:nil:OGC::IndoorGML:AnnexD'

        EXPECTED_DEFAULTS = [
          [CellSpaceType::GENERAL, 'Room', 'Space', 'Space', 'Space'],
          [CellSpaceType::TRANSITION, 'Stair', 'Stair', 'Vertical Transition', 'Stair'],
          [CellSpaceType::TRANSITION, 'Elevator', 'Elevator', 'Vertical Transition', 'Elevator'],
          [CellSpaceType::CONNECTION, 'Door', 'Door', 'Door', 'Door'],
          [CellSpaceType::ANCHOR, 'ExteriorDoor', 'Exterior door', 'Gate', 'Exterior door']
        ].freeze

        LEGACY_DEFAULTS = [
          [CellSpaceType::GENERAL, 'Room', '1000', '1000', '1000'],
          [CellSpaceType::TRANSITION, 'Stair', '1010', '1120', '1120'],
          [CellSpaceType::TRANSITION, 'Elevator', '1010', '1110', '1110'],
          [CellSpaceType::CONNECTION, 'Door', '1000', '1000', '1000'],
          [CellSpaceType::ANCHOR, 'ExteriorDoor', '1020', '1010', '1010']
        ].freeze

        def test_default_mappings_are_strings_without_code_space
          EXPECTED_DEFAULTS.each do |cell_type, category_code, class_value, function_value, usage_value|
            semantic = resolve(cell_type, category_code)

            assert_equal class_value, semantic.class_value, category_code
            assert_equal function_value, semantic.function_value, category_code
            assert_equal usage_value, semantic.usage_value, category_code
            assert_nil semantic.class_code_space, category_code
            assert_nil semantic.function_code_space, category_code
            assert_nil semantic.usage_code_space, category_code
          end
        end

        def test_category_metadata_does_not_mark_navigable_defaults_as_annex_d_standard
          EXPECTED_DEFAULTS.each do |cell_type, category_code, _class_value, _function_value, _usage_value|
            category = CellSpaceCategory.find(cell_type, category_code)

            assert_nil category[:code_space], category_code
            refute category[:standard], category_code
          end
        end

        def test_selection_options_do_not_include_escalator
          codes = CellSpaceCategory.selection_options.map { |entry| entry[:category_code] }

          refute_includes codes, 'Escalator'
        end

        def test_overrides_preserve_custom_values_and_code_spaces
          semantic = NavigationSemanticResolver.resolve(
            fake_cell(
              CellSpaceType::GENERAL,
              'Room',
              navigation_class: 'Custom Class',
              navigation_class_code_space: 'urn:custom:class',
              navigation_function: 'Custom Function',
              navigation_function_code_space: 'urn:custom:function',
              navigation_usage: 'Custom Usage',
              navigation_usage_code_space: 'urn:custom:usage'
            )
          )

          assert_equal 'Custom Class', semantic.class_value
          assert_equal 'urn:custom:class', semantic.class_code_space
          assert_equal 'Custom Function', semantic.function_value
          assert_equal 'urn:custom:function', semantic.function_code_space
          assert_equal 'Custom Usage', semantic.usage_value
          assert_equal 'urn:custom:usage', semantic.usage_code_space
        end

        def test_exporter_writes_string_values_without_code_spaces
          parent = REXML::Element.new('navi:TransitionSpace')
          writer = IndoorGmlConverter::GmlWriter.allocate

          writer.send(
            :append_navigable_space_codes,
            parent,
            fake_cell(CellSpaceType::TRANSITION, 'Stair')
          )

          assert_code parent, 'navi:class', 'Stair'
          assert_code parent, 'navi:function', 'Vertical Transition'
          assert_code parent, 'navi:usage', 'Stair'
        end

        def test_new_cell_space_persists_string_semantics_and_removes_code_space_attributes
          group = FakeGroup.new(
            'navigation_class_code_space' => ANNEX_D_URI,
            'navigation_function_code_space' => ANNEX_D_URI,
            'navigation_usage_code_space' => ANNEX_D_URI
          )
          cell_space = CellSpace.new(group, CellSpaceType::TRANSITION, 'Elevator')

          AttributeSerializer.new.write_cell_space(cell_space)

          assert_equal 'Elevator', group.attribute('navigation_class')
          assert_equal 'Vertical Transition', group.attribute('navigation_function')
          assert_equal 'Elevator', group.attribute('navigation_usage')
          assert_nil group.attribute('navigation_class_code_space')
          assert_nil group.attribute('navigation_function_code_space')
          assert_nil group.attribute('navigation_usage_code_space')
        end

        def test_restore_migrates_exact_legacy_default_semantics_with_annex_d_code_space
          LEGACY_DEFAULTS.each do |cell_type, category_code, class_value, function_value, usage_value|
            group = FakeGroup.new
            cell_space = restore_cell_space(
              group,
              cell_type,
              category_code,
              class_value,
              ANNEX_D_URI,
              function_value,
              ANNEX_D_URI,
              usage_value,
              ANNEX_D_URI
            )

            expected = NavigationSemanticResolver.default_for(cell_type, category_code)
            assert_equal expected.class_value, cell_space.navigation_class, category_code
            assert_equal expected.function_value, cell_space.navigation_function, category_code
            assert_equal expected.usage_value, cell_space.navigation_usage, category_code
            assert_nil cell_space.navigation_class_code_space, category_code
            assert_nil cell_space.navigation_function_code_space, category_code
            assert_nil cell_space.navigation_usage_code_space, category_code

            AttributeSerializer.new.write_cell_space(cell_space)
            assert_equal expected.class_value, group.attribute('navigation_class'), category_code
            assert_nil group.attribute('navigation_class_code_space'), category_code
          end
        end

        def test_restore_migrates_exact_legacy_default_semantics_with_blank_code_space
          cell_space = restore_cell_space(
            FakeGroup.new,
            CellSpaceType::CONNECTION,
            'Door',
            '1000',
            nil,
            '1000',
            '',
            '1000',
            nil
          )

          assert_equal 'Door', cell_space.navigation_class
          assert_equal 'Door', cell_space.navigation_function
          assert_equal 'Door', cell_space.navigation_usage
          assert_nil cell_space.navigation_class_code_space
          assert_nil cell_space.navigation_function_code_space
          assert_nil cell_space.navigation_usage_code_space
        end

        def test_restore_preserves_user_semantics_when_any_value_differs
          cell_space = restore_cell_space(
            FakeGroup.new,
            CellSpaceType::ANCHOR,
            'ExteriorDoor',
            'Custom exterior',
            ANNEX_D_URI,
            '1010',
            ANNEX_D_URI,
            '1010',
            ANNEX_D_URI
          )

          assert_equal 'Custom exterior', cell_space.navigation_class
          assert_equal ANNEX_D_URI, cell_space.navigation_class_code_space
          assert_equal '1010', cell_space.navigation_function
          assert_equal ANNEX_D_URI, cell_space.navigation_function_code_space
          assert_equal '1010', cell_space.navigation_usage
          assert_equal ANNEX_D_URI, cell_space.navigation_usage_code_space
        end

        def test_restore_preserves_user_semantics_when_code_space_is_custom
          cell_space = restore_cell_space(
            FakeGroup.new,
            CellSpaceType::TRANSITION,
            'Stair',
            '1010',
            'urn:custom',
            '1120',
            ANNEX_D_URI,
            '1120',
            ANNEX_D_URI
          )

          assert_equal '1010', cell_space.navigation_class
          assert_equal 'urn:custom', cell_space.navigation_class_code_space
          assert_equal '1120', cell_space.navigation_function
          assert_equal ANNEX_D_URI, cell_space.navigation_function_code_space
          assert_equal '1120', cell_space.navigation_usage
          assert_equal ANNEX_D_URI, cell_space.navigation_usage_code_space
        end

        def test_geometry_only_window_remains_without_navigation_semantics
          group = FakeGroup.new('navigation_class' => 'Space')
          cell_space = CellSpace.new(group, CellSpaceType::GEOMETRY_ONLY, 'Window')

          AttributeSerializer.new.write_cell_space(cell_space)

          assert_nil cell_space.navigation_class
          assert_nil group.attribute('navigation_class')
          assert_nil group.attribute('navigation_class_code_space')
        end

        private

        def resolve(cell_type, category_code)
          NavigationSemanticResolver.resolve(fake_cell(cell_type, category_code))
        end

        def fake_cell(cell_type, category_code, **overrides)
          FakeCellSpace.new(
            id: 'cell_test',
            cell_type: cell_type,
            category_code: category_code,
            **overrides
          )
        end

        def restore_cell_space(group, cell_type, category_code, class_value, class_code_space, function_value, function_code_space, usage_value, usage_code_space)
          CellSpace.restore(
            group,
            cell_type,
            category_code: category_code,
            navigation_class: class_value,
            navigation_class_code_space: class_code_space,
            navigation_function: function_value,
            navigation_function_code_space: function_code_space,
            navigation_usage: usage_value,
            navigation_usage_code_space: usage_code_space
          )
        end

        def assert_code(parent, tag, value)
          element = parent.elements[tag]
          refute_nil element
          assert_equal value, element.text
          assert_nil element.attributes['codeSpace']
        end

        class FakeGroup < Sketchup::Group
          def initialize(attributes = {})
            @attributes = { AttributeSerializer::ATTRIBUTE_DICTIONARY_NAME => attributes.dup }
          end

          def valid?
            true
          end

          def manifold?
            true
          end

          def persistent_id
            1
          end

          def set_attribute(dictionary, key, value)
            @attributes[dictionary] ||= {}
            @attributes[dictionary][key] = value
          end

          def get_attribute(dictionary, key, default = nil)
            @attributes.fetch(dictionary, {}).fetch(key, default)
          end

          def delete_attribute(dictionary, key)
            @attributes.fetch(dictionary, {}).delete(key)
          end

          def attribute(key)
            get_attribute(AttributeSerializer::ATTRIBUTE_DICTIONARY_NAME, key)
          end
        end
      end
    end
  end
end
