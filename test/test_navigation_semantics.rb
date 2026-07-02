# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/domain/navigation_semantic'
require_relative '../indoor3d/export/gml_exporter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class NavigationSemanticTest < Minitest::Test
        FakeCellSpace = Struct.new(
          :id,
          :cell_type,
          :category_code,
          :category_label,
          :navigation_class,
          :navigation_class_code_space,
          :navigation_function,
          :navigation_function_code_space,
          :navigation_usage,
          :navigation_usage_code_space,
          keyword_init: true
        )

        ANNEX_D = NavigationSemanticResolver::ANNEX_D_CODE_SPACE

        def test_transition_stair_mapping
          semantic = resolve(CellSpaceType::TRANSITION, 'Stair')

          assert_equal '1010', semantic.class_value
          assert_equal '1120', semantic.function_value
          assert_equal '1120', semantic.usage_value
          assert_equal ANNEX_D, semantic.class_code_space
          assert_equal ANNEX_D, semantic.function_code_space
          assert_equal ANNEX_D, semantic.usage_code_space
        end

        def test_transition_elevator_mapping
          semantic = resolve(CellSpaceType::TRANSITION, 'Elevator')

          assert_equal '1010', semantic.class_value
          assert_equal '1110', semantic.function_value
          assert_equal '1110', semantic.usage_value
        end

        def test_connection_door_mapping
          semantic = resolve(CellSpaceType::CONNECTION, 'Door')

          assert_equal '1000', semantic.class_value
          assert_equal '1000', semantic.function_value
          assert_equal '1000', semantic.usage_value
        end

        def test_general_room_has_default_mapping
          semantic = resolve(CellSpaceType::GENERAL, 'Room')

          assert_equal '1000', semantic.class_value
          assert_equal '1000', semantic.function_value
          assert_equal '1000', semantic.usage_value
          assert_equal ANNEX_D, semantic.class_code_space
          assert_equal ANNEX_D, semantic.function_code_space
          assert_equal ANNEX_D, semantic.usage_code_space
        end

        def test_anchor_exterior_door_mapping
          semantic = resolve(CellSpaceType::ANCHOR, 'ExteriorDoor')

          assert_equal '1020', semantic.class_value
          assert_equal '1010', semantic.function_value
          assert_equal '1010', semantic.usage_value
          assert_equal ANNEX_D, semantic.class_code_space
          assert_equal ANNEX_D, semantic.function_code_space
          assert_equal ANNEX_D, semantic.usage_code_space
        end

        def test_general_room_can_override_semantic_values
          semantic = NavigationSemanticResolver.resolve(
            fake_cell(
              CellSpaceType::GENERAL,
              'Room',
              navigation_class: '1020',
              navigation_function: '1260',
              navigation_usage: '1260'
            )
          )

          assert_equal '1020', semantic.class_value
          assert_equal '1260', semantic.function_value
          assert_equal '1260', semantic.usage_value
        end

        def test_transition_space_can_override_semantic_values
          semantic = NavigationSemanticResolver.resolve(
            fake_cell(
              CellSpaceType::TRANSITION,
              'Stair',
              navigation_class: '1010',
              navigation_function: '1060',
              navigation_usage: '1060'
            )
          )

          assert_equal '1010', semantic.class_value
          assert_equal '1060', semantic.function_value
          assert_equal '1060', semantic.usage_value
        end

        def test_connection_space_can_override_semantic_values
          semantic = NavigationSemanticResolver.resolve(
            fake_cell(
              CellSpaceType::CONNECTION,
              'Door',
              navigation_class: '1000',
              navigation_function: '1010',
              navigation_usage: '1010'
            )
          )

          assert_equal '1000', semantic.class_value
          assert_equal '1010', semantic.function_value
          assert_equal '1010', semantic.usage_value
        end

        def test_legacy_escalator_category_migrates_to_stair
          category = CellSpaceCategory.normalize(CellSpaceType::TRANSITION, 'Escalator')
          semantic = resolve(CellSpaceType::TRANSITION, 'Escalator')

          assert_equal 'Stair', category[:code]
          assert_equal 'Stair', category[:label]
          assert_equal '1120', semantic.function_value
        end

        def test_exporter_writes_values_and_per_property_code_spaces
          parent = REXML::Element.new('navi:TransitionSpace')
          writer = IndoorGmlConverter::GmlWriter.allocate

          writer.send(
            :append_navigable_space_codes,
            parent,
            fake_cell(CellSpaceType::TRANSITION, 'Stair')
          )

          assert_code parent, 'navi:class', '1010'
          assert_code parent, 'navi:function', '1120'
          assert_code parent, 'navi:usage', '1120'
        end

        def test_exporter_writes_anchor_space_codes
          parent = REXML::Element.new('navi:AnchorSpace')
          writer = IndoorGmlConverter::GmlWriter.allocate

          writer.send(
            :append_navigable_space_codes,
            parent,
            fake_cell(CellSpaceType::ANCHOR, 'ExteriorDoor')
          )

          assert_code parent, 'navi:class', '1020'
          assert_code parent, 'navi:function', '1010'
          assert_code parent, 'navi:usage', '1010'
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
            category_label: category_code,
            **overrides
          )
        end

        def assert_code(parent, tag, value)
          element = parent.elements[tag]
          refute_nil element
          assert_equal value, element.text
          assert_equal ANNEX_D, element.attributes['codeSpace']
        end
      end
    end
  end
end
