# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/indoor_model/feature_lifecycle'

class CellSpaceCopyReferenceGraphTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore

  module Core::Logger
    def self.puts(_message = nil); end unless respond_to?(:puts)
  end unless Core.const_defined?(:Logger, false)

  FakeEntity = Struct.new(:entityID)
  FakeState = Struct.new(:id)

  class FakeCell
    attr_reader :id, :duality_state

    def initialize(id, state)
      @id = id
      @duality_state = state
    end

    def create_duality_state(_parent_entities)
      @duality_state
    end
  end

  class Harness
    include Core::IndoorModel::FeatureLifecycle

    attr_reader :calls

    def initialize(local_grid: true, fail_adjacency: false)
      @local_grid = local_grid
      @fail_adjacency = fail_adjacency
      @calls = []
      @state = FakeState.new('new-state')
      @cell = FakeCell.new('new-cell', @state)
    end

    def indoor_attribute(_entity, name)
      { 'id' => 'copied-cell', 'duality_state_id' => 'copied-state' }[name]
    end

    def cell_space_copy_independence_runtime_snapshot
      :runtime_snapshot
    end

    def with_transparent_cell_space_operation(_name)
      yield
    end

    def sync
      yield
    end

    def make_cell_space_entity_unique(_entity)
      @calls << :make_unique
      true
    end

    def build_independent_cell_space(_entity)
      @calls << :build
      @cell
    end

    def ensure_unique_feature_id!(feature, reserved_ids: [])
      @calls << [:unique, feature.id, reserved_ids]
      feature
    end

    def register_cell_space(_cell_space)
      @calls << :register_cell
    end

    def register_state(_state)
      @calls << :register_state
    end

    def local_grid_coordinate_enabled?
      @local_grid
    end

    def finish_cell_space_geometry_local_grid(_cell_space)
      @calls << :local_grid_reference
    end

    def recenter_cell_space_origin(_cell_space)
      @calls << :standard_reference
    end

    def name_cell_space_entity(_cell_space)
      @calls << :name
    end

    def apply_cell_space_material(_cell_space)
      @calls << :material
    end

    def write_cell_space_attributes(_cell_space)
      @calls << :write
    end

    def synchronize_adjacency_and_transitions_for_cell_space(_cell_space)
      @calls << :adjacency
      raise 'adjacency failed' if @fail_adjacency
    end

    def remember_cell_space_change_snapshot(_entity)
      @calls << :remember
    end

    def erase_independent_cell_space_reference_graph(cell_space)
      @calls << [:erase_reference, cell_space&.id]
    end

    def restore_cell_space_copy_independence_runtime(snapshot)
      @calls << [:restore, snapshot]
    end

    def clear_copied_cell_space_indoor_attributes(_entity)
      @calls << :clear_attributes
    end

    def log_cell_space_copy_independence_failure(error)
      @calls << [:log_failure, error.message]
    end

    def defer_cell_space_copy_independence_failure_warning
      @calls << :warn
    end
  end

  def test_copy_builds_local_grid_reference_graph_before_adjacency
    harness = Harness.new(local_grid: true)

    assert harness.send(:make_cell_space_copy_independent, FakeEntity.new(42))

    assert_operator harness.calls.index(:register_state), :<,
                    harness.calls.index(:local_grid_reference)
    assert_operator harness.calls.index(:local_grid_reference), :<,
                    harness.calls.index(:adjacency)
    refute_includes harness.calls, :standard_reference
  end

  def test_copy_uses_standard_reference_graph_pipeline_outside_local_grid_mode
    harness = Harness.new(local_grid: false)

    assert harness.send(:make_cell_space_copy_independent, FakeEntity.new(43))

    assert_includes harness.calls, :standard_reference
    refute_includes harness.calls, :local_grid_reference
  end

  def test_copy_failure_erases_committed_reference_graph_before_runtime_rollback
    harness = Harness.new(local_grid: true, fail_adjacency: true)

    refute harness.send(:make_cell_space_copy_independent, FakeEntity.new(44))

    erase_index = harness.calls.index([:erase_reference, 'new-cell'])
    restore_index = harness.calls.index([:restore, :runtime_snapshot])
    refute_nil erase_index
    refute_nil restore_index
    assert_operator erase_index, :<, restore_index
  end
end
