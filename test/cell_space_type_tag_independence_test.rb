# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
      end unless const_defined?(:IndoorModel)
      IndoorModel.const_set(:ATTRIBUTE_DICTIONARY_NAME, 'IndoorGML') unless IndoorModel.const_defined?(:ATTRIBUTE_DICTIONARY_NAME)
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_type_change_optimization'
require_relative '../indoor3d/ui/commands/base_commands'

class CellSpaceTypeTagIndependenceTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore

  class Cell
    attr_accessor :cell_type, :category_code
    attr_reader :duality_state

    def initialize(cell_type, category_code)
      @cell_type = cell_type
      @category_code = category_code
      @duality_state = Object.new
    end

    def valid?
      true
    end

    def navigable?
      true
    end
  end

  class Lifecycle
    attr_reader :changes

    def initialize
      @changes = []
    end

    def change_type(cell, cell_type:, category_code:)
      @changes << [cell_type, category_code]
      cell.cell_type = cell_type
      cell.category_code = category_code
    end
  end

  class ChangeHarness
    include Core::IndoorModel::CellSpaceTypeChangeOptimization

    attr_reader :lifecycle

    def initialize(cell)
      @cell = cell
      @lifecycle = Lifecycle.new
    end

    def find_cell_space_for_entity(_group)
      @cell
    end

    def cell_space_lifecycle_service
      @lifecycle
    end

    def with_validation_focus_mutation_batch
      yield
    end

    def with_bulk_cell_space_conversion
      yield
    end

    def with_indoor_model_operation(*_args, **_options)
      yield
    end

    def sync
      yield
    end

    def apply_cell_space_materials_batch(_cells); end

    def apply_indoor_lock_policy; end

    def tag_cell_space_type_change_target(*_args)
      raise 'Tag resolver must not be called'
    end
  end

  TaggedGroup = Struct.new(:feature) do
    def get_attribute(_dictionary, key, default = nil)
      key == 'feature' ? feature : default
    end
  end

  def test_requested_type_is_applied_without_tag_resolution
    cell = Cell.new(:general, 'Room')
    harness = ChangeHarness.new(cell)

    changed = harness.change_cell_space_types(
      [Object.new],
      :transition,
      'Stair'
    )

    assert_equal [cell], changed
    assert_equal [[:transition, 'Stair']], harness.lifecycle.changes
  end

  def test_type_change_command_is_available_for_any_cell_space
    command = Object.new.extend(Core::BaseCommands)

    assert command.cell_space_type_change_available?([TaggedGroup.new('CellSpace')])
    refute command.cell_space_type_change_available?([TaggedGroup.new(nil)])
  end
end
