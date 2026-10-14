# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/room_internal_visibility_graph'

class RoomInternalVisibilityGraphTest < Minitest::Test
  Builder = ULOL::Indoor3DGmlModeler::IndoorCore::RoomInternalVisibilityGraph
  Point = Struct.new(:x, :y, :z)

  def node(x, y, z = 0.5)
    { point: Point.new(x.to_f, y.to_f, z.to_f), radius: 0.0 }.freeze
  end

  def graph(nodes, edges = [])
    { nodes: nodes.freeze, edges: edges.map(&:freeze).freeze,
      original_indices: (0...nodes.size).to_a.freeze }.freeze
  end

  def test_all_pairs_are_tested_regardless_of_initial_edges_and_radii
    original = graph([node(0, 0), node(3, 0), node(3, 4)])
    checked = []
    native = lambda do |pairs|
      checked.concat(pairs.map { |a, b| [a.x, a.y, b.x, b.y] })
      [true, false, true]
    end

    result = Builder.build(original, los_batch: native)

    assert_equal 3, result[:checked_pairs]
    assert_equal 2, result[:visible_pairs]
    assert_equal [[0, 1], [1, 2]], result[:edges]
    assert_equal [3.0, 4.0], result[:edge_weights]
    assert_equal 0, result[:original_indices][0]
    assert_equal :optimized, result[:source_stage]
    assert_equal [[0.0, 0.0, 3.0, 0.0],
                  [0.0, 0.0, 3.0, 4.0],
                  [3.0, 0.0, 3.0, 4.0]], checked
    assert_equal [], original[:edges]
  end

  def test_native_los_rejects_blocked_crossing_even_when_old_edge_exists
    original = graph([node(0, 0), node(1, 0)], [[0, 1]])
    result = Builder.build(original, los_batch: ->(_pairs) { [false] })
    assert_empty result[:edges]
    assert_empty result[:edge_weights]
    assert_equal [[0, 1]], original[:edges]
  end

  def test_single_state_only_produces_empty_edges
    result = Builder.build(graph([node(0, 0)]), los_batch: ->(_pairs) { flunk })
    assert_equal 1, result[:nodes].size
    assert_empty result[:edges]
    assert_equal 0, result[:checked_pairs]
  end

  def test_long_list_is_batched_without_skipping_any_pair
    original = graph(Array.new(65) { |i| node(i, 0) })
    batches = []
    result = Builder.build(original, los_batch: lambda { |pairs|
      batches << pairs.size
      Array.new(pairs.size, true)
    })
    assert_equal [2048, 32], batches
    assert_equal 2080, result[:checked_pairs]
    assert_equal 2080, result[:edges].size
    assert_equal 2080, result[:edge_weights].size
  end

  def test_invalid_native_result_raises_without_partial_graph
    original = graph([node(0, 0), node(1, 0)])
    assert_raises(ArgumentError) { Builder.build(original, los_batch: ->(_p) { [] }) }
    assert_raises(ArgumentError) { Builder.build(original, los_batch: ->(_p) { [nil] }) }
  end

  def test_limits_prevent_unbounded_all_pairs_allocation
    original = graph(Array.new(Builder::MAX_NODES + 1) { |i| node(i, 0) })
    assert_raises(ArgumentError) do
      Builder.build(original, los_batch: ->(_pairs) { flunk })
    end
  end

  def test_missing_state_origin_is_rejected
    source = graph([node(0, 0), node(1, 0)]).merge(original_indices: [4, 5])
    assert_raises(ArgumentError) do
      Builder.build(source, los_batch: ->(_pairs) { flunk })
    end
  end

  def test_state_and_reference_locations_are_never_changed
    nodes = [node(0, 0), node(0.5, 0.5), node(0.9, 0.1)]
    original = graph(nodes)
    result = Builder.build(original, los_batch: ->(pairs) { Array.new(pairs.size, true) })
    assert_same original[:nodes][0], result[:nodes][0]
    assert_equal original[:nodes], result[:nodes]
    assert_equal original[:original_indices], result[:original_indices]
  end
end
