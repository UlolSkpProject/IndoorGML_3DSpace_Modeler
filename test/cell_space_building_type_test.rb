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

module UI
  class << self
    attr_accessor :response, :arguments

    def inputbox(*args)
      self.arguments = args
      response
    end
  end
end

class CellSpaceBuildingTypeTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Adapter = Core::TagCellSpaceAdapter
  Model = Struct.new(:attributes) do
    def get_attribute(dictionary, key, default = nil)
      attributes.fetch([dictionary, key], default)
    end

    def set_attribute(dictionary, key, value)
      attributes[[dictionary, key]] = value
    end
  end

  def setup
    Sketchup.active_model = Model.new({})
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

  def test_creation_dialog_selects_and_remembers_building_before_classification
    UI.response = ['공공기관', 'Room : GeneralSpace', 'F02']
    options = @command.send(:prompt_cell_space_creation_options, 'Create CellSpace', default_storey: 'F01')

    assert_equal [Core::CellSpaceType::GENERAL, 'Room', 'F02'], options
    assert_equal '지하철|공공기관', UI.arguments[2][0]
    assert_equal 'public', Adapter.building_type
    assert_equal [Core::CellSpaceType::TRANSITION, 'Elevator'], Adapter.cell_space_type_from_tag('F01F03_MV_FC_02')

    UI.response = false
    assert_nil @command.send(:prompt_cell_space_creation_options, 'Create CellSpace', default_storey: 'F01')
    assert_equal '공공기관', UI.arguments[1][0]
    assert_equal 'public', Adapter.building_type
  end

  def test_models_keep_independent_building_settings
    first_model = Sketchup.active_model
    Adapter.set_building_type(first_model, 'public')
    Sketchup.active_model = Model.new({})
    assert_equal 'subway', Adapter.building_type
    assert_equal 'public', Adapter.building_type(first_model)
    assert_equal [Core::CellSpaceType::TRANSITION, 'Stair'], Adapter.cell_space_type_from_tag('F01F03_MV_FC_02')
  end
end
