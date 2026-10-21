# frozen_string_literal: true

require 'minitest/autorun'

# Standalone topology fixture: no SketchUp process or native module needed.
class Integer
  def mm
    to_f / 25.4
  end unless method_defined?(:mm)
end

module Geom
  Point3d = Struct.new(:x, :y, :z) do
    def distance(other)
      Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    end
  end
  Vector3d = Struct.new(:x, :y, :z)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpace
        attr_reader :id, :duality_state, :sketchup_group

        def initialize(id)
          @id = id
          @sketchup_group = nil
        end

        def restore_duality_state(state)
          @duality_state = state
        end

        def navigable? = true
        def valid? = true
        def valid_sketchup_group = nil
      end
    end
  end
end

require_relative '../indoor3d/domain/abstract_feature'
require_relative '../indoor3d/domain/state'
require_relative '../indoor3d/domain/transition'
require_relative '../indoor3d/application/feature_registry'
require_relative '../indoor3d/application/indoor_model/topology'

class TransitionStateReferenceSyncTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore

  class Harness
    include Core::IndoorModel::Topology

    attr_reader :registry, :transition_writes, :state_writes

    def initialize
      @feature_registry = Core::FeatureRegistry.new
      @registry = @feature_registry
      @transition_writes = []
      @state_writes = []
    end

    def cell_pair_key(first, second)
      [first.id, second.id].sort.join(':')
    end

    def state_root_local_position(state)
      state.position
    end

    def refresh_transition_waypoint_candidates(_transition); end

    def write_state_attributes(state)
      @state_writes << state
    end

    def write_transition_attributes(transition)
      @transition_writes << transition
    end

    def invalidate_overlay_transition_points; end

    def sync_pair(first, second, runtime: false)
      name = runtime ? :create_or_update_runtime_transition_for_pair :
                       :create_or_update_transition_for_pair
      send(name, first, second)
    end
  end

  def setup
    @model = Harness.new
    @first = Core::CellSpace.new('a')
    @second = Core::CellSpace.new('b')
    @original_first = register_state(@first, 0.0)
    @original_second = register_state(@second, 10.0)
  end

  def register_state(cell, x)
    state = Core::State.new(cell, nil, Geom::Point3d.new(x, 0.0, 0.0))
    cell.restore_duality_state(state)
    @model.registry.add_state(state)
    state
  end

  def replace_state(cell, previous, x)
    @model.registry.remove_state(previous)
    register_state(cell, x)
  end

  def assert_links(transition, first_state, second_state)
    assert_same first_state, transition.state1
    assert_same second_state, transition.state2
    assert_includes first_state.transitions, transition
    assert_includes second_state.transitions, transition
    assert_equal [transition], @model.registry.transitions
    assert_same transition, @model.registry.transition_for_pair('a:b')
  end

  def test_matching_pair_keeps_transition_identity_when_input_order_changes
    original = @model.sync_pair(@first, @second)
    assert_same original, @model.sync_pair(@second, @first)
    assert_same original, @model.sync_pair(@first, @second)
    assert_links(original, @original_first, @original_second)
    assert_equal 1, @original_first.transitions.count(original)
  end

  def test_persistent_path_replaces_stale_state_even_if_old_transition_is_valid
    old_transition = @model.sync_pair(@first, @second)
    old_id = old_transition.id
    replacement = replace_state(@first, @original_first, 2.0)
    assert old_transition.valid?, 'Old State#valid? only checks its CellSpace'

    fresh = @model.sync_pair(@first, @second)
    refute_same old_transition, fresh
    assert_links(fresh, replacement, @original_second)
    assert_empty @original_first.transitions
    refute_includes @original_second.transitions, old_transition
    assert_nil @model.registry.feature_by_id(old_id)
    assert_same fresh, @model.registry.feature_by_id(fresh.id)
    refute old_transition.valid?
    assert_same fresh, @model.sync_pair(@second, @first)
  end

  def test_runtime_path_replaces_stale_pair_without_persistent_writes
    stale = @model.sync_pair(@first, @second, runtime: true)
    replacement = replace_state(@second, @original_second, 12.0)
    assert stale.valid?

    fresh = @model.sync_pair(@second, @first, runtime: true)
    refute_same stale, fresh
    assert_links(fresh, replacement, @original_first)
    assert_empty @original_second.transitions
    refute_includes @original_first.transitions, stale
    assert_same fresh, @model.sync_pair(@first, @second, runtime: true)
    assert_empty @model.state_writes
    assert_empty @model.transition_writes
  end

  def test_same_pair_id_but_replaced_cell_object_must_rebuild_transition
    stale = @model.sync_pair(@first, @second)
    restored_cell = Core::CellSpace.new('a')
    restored_state = register_state(restored_cell, 3.0)

    assert_equal @first.id, restored_cell.id
    refute_same @first, restored_cell
    assert stale.valid?

    current = @model.sync_pair(restored_cell, @second)
    refute_same stale, current
    assert_links(current, restored_state, @original_second)
    assert_empty @original_first.transitions
    refute_includes @original_second.transitions, stale
  end

  def test_runtime_path_keeps_existing_transition_when_states_are_current
    existing = @model.sync_pair(@first, @second, runtime: true)
    assert_same existing, @model.sync_pair(@second, @first, runtime: true)
    assert_links(existing, @original_first, @original_second)
  end
end
