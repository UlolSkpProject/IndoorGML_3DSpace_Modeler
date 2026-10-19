# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        ADJACENCY_TOLERANCE = 0.01 unless const_defined?(:ADJACENCY_TOLERANCE)

        def self.adjacency_snapshot(group)
          group.snapshot
        end
      end
    end
  end
end

require_relative '../indoor3d/application/adjacency_service/sync'
require_relative '../indoor3d/application/adjacency_service/native_integration'

class AdjacencyDirtyBatchTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Bridge = Core::NativeAdjacencyBridge

  FakeGroup = Struct.new(:snapshot)
  FakeState = Struct.new(:valid) do
    def valid?
      valid
    end
  end

  class FakeCell
    attr_reader :id, :duality_state, :sketchup_group

    def initialize(id)
      @id = id
      @duality_state = FakeState.new(true)
      @sketchup_group = FakeGroup.new({ cell_id: id })
    end

    def valid?
      true
    end

    def navigable?
      true
    end
  end

  class FakeRegistry
    attr_reader :cell_spaces

    def initialize(cell_spaces, transition_pair_keys)
      @cell_spaces = cell_spaces
      @transition_pair_keys = transition_pair_keys
    end

    def transition_pair_keys_for_cell(cell_id)
      @transition_pair_keys.select { |key| key.split(':').include?(cell_id) }
    end
  end

  def test_two_dirty_cells_serialize_once_and_upsert_pairs_only_once
    a, b, c, d = %w[A B C D].map { |id| FakeCell.new(id) }
    # The previously adjacent pairs A:C and A:B must be reevaluated.
    # C:D is unrelated to this dirty set and must stay untouched.
    registry = FakeRegistry.new([a, b, c, d], %w[A:B A:C B:C C:D])
    upserts = []
    erases = []
    service = Core::AdjacencyService.new(
      registry,
      transition_builder: proc { |left, right| upserts << [left.id, right.id] },
      transition_eraser: proc { |key| erases << key }
    )
    # Snapshot waypoint memoization is orthogonal to dirty batching.
    service.define_singleton_method(:prepare_snapshot_waypoint_contexts) { |_entries| }

    native_calls = []
    native_result = {
      pair_results: [[0, 1, :x], [1, 2, :x]],
      contexts: [],
      metrics: { candidate_count: 2 }
    }

    Bridge.stub(:incremental_supported?, true) do
      Bridge.stub(:shared_session_active?, false) do
        Bridge.stub(:compute_incremental, proc { |snapshots, dirty_indices:, tolerance:, keys:|
          native_calls << {
            snapshots: snapshots, dirty_indices: dirty_indices,
            tolerance: tolerance, keys: keys
          }
          native_result
        }) do
          service.synchronize_dirty([a, b, a])
        end
      end
    end

    assert_equal 1, native_calls.length, 'one load_batch must cover all dirty cells'
    assert_equal %w[A B C D], native_calls.first[:keys]
    assert_equal [0, 1], native_calls.first[:dirty_indices]
    assert_equal 4, native_calls.first[:snapshots].length
    assert_equal [['A', 'B'], ['B', 'C']], upserts
    assert_equal ['A:C'], erases
  end

  def test_synchronize_for_remains_a_one_cell_wrapper
    a, b = %w[A B].map { |id| FakeCell.new(id) }
    registry = FakeRegistry.new([a, b], [])
    service = Core::AdjacencyService.new(
      registry,
      transition_builder: proc { |_left, _right| },
      transition_eraser: proc { |_key| }
    )
    service.define_singleton_method(:prepare_snapshot_waypoint_contexts) { |_entries| }

    dirty_calls = []
    Bridge.stub(:incremental_supported?, true) do
      Bridge.stub(:shared_session_active?, false) do
        Bridge.stub(:compute_incremental, proc { |_snapshots, dirty_indices:, **_kwargs|
          dirty_calls << dirty_indices
          { pair_results: [[0, 1, :x]], contexts: [], metrics: { candidate_count: 1 } }
        }) do
          service.synchronize_for(a)
        end
      end
    end

    assert_equal [[0]], dirty_calls
  end
end
