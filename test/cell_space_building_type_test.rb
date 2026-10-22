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

  def test_creation_dialog_defaults_from_filename_and_saves_submitted_building
    payload = @command.send(
      :cell_space_creation_dialog_payload,
      'Create CellSpace',
      default_storey: 'F01'
    )

    assert_equal 'subway', payload[:selected_building]
    assert_equal(
      [
        { value: '', label: '건축물 구분 선택' },
        { value: 'subway', label: '지하철' },
        { value: 'public', label: '공공기관' }
      ],
      payload[:building_types]
    )

    options = @command.send(
      :resolve_cell_space_creation_dialog_selection,
      {
        'building_type' => 'public',
        'cell_space_label' => 'Room : GeneralSpace',
        'storey' => 'F02'
      }
    )

    assert_equal [Core::CellSpaceType::GENERAL, 'Room', 'F02'], options
    assert_equal 'public', Adapter.building_type
    assert_equal [Core::CellSpaceType::TRANSITION, 'Elevator'], Adapter.cell_space_type_from_tag('F01F03_MV_FC_02')

    next_payload = @command.send(
      :cell_space_creation_dialog_payload,
      'Create CellSpace',
      default_storey: 'F01'
    )
    assert_equal 'subway', next_payload[:selected_building]
  end

  def test_nonmatching_filename_leaves_building_type_unselected
    Sketchup.active_model = Model.new({}, 'C:\\models\\ordinary.skp')

    payload = @command.send(
      :cell_space_creation_dialog_payload,
      'Create CellSpace',
      default_storey: 'F01'
    )
    assert_nil payload[:selected_building]

    error = assert_raises(ArgumentError) do
      @command.send(
        :resolve_cell_space_creation_dialog_selection,
        {
          'building_type' => '',
          'cell_space_label' => 'Room : GeneralSpace',
          'storey' => 'F01'
        }
      )
    end
    assert_equal '건축물 구분을 선택하세요.', error.message
  end

  def test_models_keep_independent_building_settings
    first_model = Sketchup.active_model
    Adapter.set_building_type(first_model, 'public')
    Sketchup.active_model = Model.new({}, 'C:\\models\\P_SB_260930_library.skp')
    assert_equal 'public', Adapter.building_type
    assert_equal 'public', @command.send(
      :cell_space_creation_dialog_payload,
      'Create CellSpace',
      default_storey: 'F01'
    )[:selected_building]
    assert_equal 'public', Adapter.building_type(first_model)
    assert_equal [Core::CellSpaceType::TRANSITION, 'Elevator'], Adapter.cell_space_type_from_tag('F01F03_MV_FC_02')
  end
end
