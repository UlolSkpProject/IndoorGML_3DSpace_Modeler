# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/integration/tag_cell_space_adapter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class TagCellSpaceAdapterTest < Minitest::Test
        def test_storey_from_tag_name_reads_single_floor_prefix
          assert_equal 'F01', TagCellSpaceAdapter.storey_from_tag_name('F01F01_IP_RM_23')
          assert_equal 'B04', TagCellSpaceAdapter.storey_from_tag_name('B04B04_IP_RM_23')
        end

        def test_storey_from_tag_name_reads_range_prefix
          assert_equal 'F01~F03', TagCellSpaceAdapter.storey_from_tag_name('F01F03_MV_RM_02')
          assert_equal 'B02~F01', TagCellSpaceAdapter.storey_from_tag_name('B02F01_MV_RM_01')
        end

        def test_storey_from_tag_name_rejects_invalid_or_untagged_names
          assert_nil TagCellSpaceAdapter.storey_from_tag_name('bad')
          assert_nil TagCellSpaceAdapter.storey_from_tag_name('Untagged')
          assert_nil TagCellSpaceAdapter.storey_from_tag_name('')
          assert_nil TagCellSpaceAdapter.storey_from_tag_name('F00F01_IP_RM_23')
        end

        def test_resolve_cell_space_storey_keeps_range_for_stair_and_elevator
          assert_equal(
            'F01~F03',
            TagCellSpaceAdapter.resolve_cell_space_storey(
              fake_tagged_entity('F01F03_MV_RM_02'),
              CellSpaceType::TRANSITION,
              'Stair',
              'F01'
            )
          )
          assert_equal(
            'B02~F01',
            TagCellSpaceAdapter.resolve_cell_space_storey(
              fake_tagged_entity('B02F01_MV_RM_01'),
              CellSpaceType::TRANSITION,
              'Elevator',
              'F01'
            )
          )
        end

        def test_resolve_cell_space_storey_uses_start_floor_for_non_range_cell_types
          assert_equal(
            'F01',
            TagCellSpaceAdapter.resolve_cell_space_storey(
              fake_tagged_entity('F01F03_IP_RM_23'),
              CellSpaceType::GENERAL,
              'Room',
              'F09'
            )
          )
        end

        def test_resolve_cell_space_storey_value_applies_range_policy_to_propagated_value
          assert_equal(
            'F01~F03',
            TagCellSpaceAdapter.resolve_cell_space_storey_value(
              'F01~F03',
              CellSpaceType::TRANSITION,
              'Stair',
              'F09'
            )
          )
          assert_equal(
            'F01',
            TagCellSpaceAdapter.resolve_cell_space_storey_value(
              'F01~F03',
              CellSpaceType::GENERAL,
              'Room',
              'F09'
            )
          )
          assert_equal(
            'F09',
            TagCellSpaceAdapter.resolve_cell_space_storey_value(
              nil,
              CellSpaceType::GENERAL,
              'Room',
              'F09'
            )
          )
        end

        def test_resolve_cell_space_storey_falls_back_to_default_without_valid_prefix
          assert_equal(
            'F09',
            TagCellSpaceAdapter.resolve_cell_space_storey(
              fake_tagged_entity('bad'),
              CellSpaceType::GENERAL,
              'Room',
              'F09'
            )
          )
        end

        private

        def fake_tagged_entity(tag_name)
          Struct.new(:layer).new(Struct.new(:name).new(tag_name))
        end
      end
    end
  end
end
