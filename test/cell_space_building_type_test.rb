# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../indoor3d/integration/tag_cell_space_adapter'
require_relative '../indoor3d/domain/cell_space_category'
require_relative '../indoor3d/ui/commands/base_commands'

# Minimal UI/model doubles; this test does not require a running SketchUp instance.
module Sketchup
  class << self
    attr_accessor :active_model
  end
end

class CellSpaceBuildingTypeTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Adapter = Core::TagCellSpaceAdapter
  Model = Struct.new(:attributes, :path) do
    def get_attribute(dictionary, key, default = nil)
      attributes.fetch([dictionary, key], default)
    end

    def set_attribute(dictionary, key, value)
      attributes[[dictionary, key]] = value
    end
  end

  def setup
    Sketchup.active_model = Model.new({}, 'C:\\models\\U_SB_260930_station.skp')
    @command = Object.new.extend(Core::BaseCommands)
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'tag_catalog.json')
      rows = [
        { division: '지하철', major_code: 'MV', minor_code: 'FC_02', minor_category: '계단' },
        { division: '공공시설건물', major_code: 'MV', minor_code: 'FC_02', minor_category: '엘리베이터' }
      ]
      File.write(path, JSON.generate(categories: rows))
      Adapter.load_catalog!(path: path)
    end
  end

  def test_creation_dialog_has_no_building_type_or_tag_dependency
    payload = @command.send(
      :cell_space_creation_dialog_payload,
      'Create CellSpace',
      default_storey: 'F01'
    )

    refute payload.key?(:selected_building)
    refute payload.key?(:building_types)

    options = @command.send(
      :resolve_cell_space_creation_dialog_selection,
      {
        'cell_space_label' => 'Room : GeneralSpace',
        'storey' => 'F02'
      }
    )

    assert_equal [Core::CellSpaceType::GENERAL, 'Room', 'F02'], options
    assert_equal 'subway', Adapter.building_type
    assert_equal [Core::CellSpaceType::TRANSITION, 'Stair'], Adapter.cell_space_type_from_tag('F01F03_MV_FC_02')
  end

  def test_nonmatching_filename_does_not_block_creation_selection
    Sketchup.active_model = Model.new({}, 'C:\\models\\ordinary.skp')

    payload = @command.send(
      :cell_space_creation_dialog_payload,
      'Create CellSpace',
      default_storey: 'F01'
    )
    refute_nil payload

    selection = @command.send(
      :resolve_cell_space_creation_dialog_selection,
      {
        'cell_space_label' => 'Room : GeneralSpace',
        'storey' => 'F01'
      }
    )
    assert_equal [Core::CellSpaceType::GENERAL, 'Room', 'F01'], selection
  end

  def test_creation_selection_does_not_change_existing_building_setting
    first_model = Sketchup.active_model
    Adapter.set_building_type(first_model, 'public')

    @command.send(
      :resolve_cell_space_creation_dialog_selection,
      {
        'cell_space_label' => 'Room : GeneralSpace',
        'storey' => 'F01'
      }
    )

    assert_equal 'public', Adapter.building_type(first_model)
    assert_equal [Core::CellSpaceType::TRANSITION, 'Elevator'], Adapter.cell_space_type_from_tag('F01F03_MV_FC_02')
  end
end
