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

  def test_optimized_edges_and_nodes_are_preserved
    original = graph([node(0, 0), node(1, 0), node(4, 0), node(5, 0)],
                     [[0, 1], [2, 3]])
    result = Builder.build(original, los_batch: ->(pairs) { Array.new(pairs.size, true) })

    assert_equal [[0, 1], [2, 3]], result[:edges].first(2)
    assert_equal [[1, 2]], result[:added_edges].map { |item| item[:edge] }
    assert_equal :clear, result[:added_edges].first[:classification]
    assert_equal 1, result[:clear_added_count]
    assert_equal 0, result[:blocked_added_count]
    assert_equal 2, result[:component_count_before]
    assert_equal 1, result[:component_count_after]
    assert_equal 1, result[:edges].size - original[:edges].size
    assert_equal original[:nodes], result[:nodes]
    assert_equal original[:edges], [[0, 1], [2, 3]]
  end

  def test_connected_optimized_graph_needs_no_los_calls
    original = graph([node(0, 0), node(1, 0), node(2, 0)], [[0, 1], [1, 2]])
    result = Builder.build(original, los_batch: ->(_pairs) { flunk 'unexpected LOS call' })

    assert_equal original[:edges], result[:edges]
    assert_equal 0, result[:checked_pairs]
    assert_empty result[:added_edges]
    assert_equal 1, result[:component_count_before]
  end

  def test_unobstructed_candidates_take_priority_over_short_blocked_edge
    # A at x=0; B at x=1; C at x=10.
    # Short AB is blocked; longer AC/BC are clear.
    original = graph([node(0, 0), node(1, 0), node(10, 0)])
    result = Builder.build(original, los_batch: lambda { |pairs|
      pairs.map { |a, b| a.x != 0.0 || b.x != 1.0 }
    })

    assert_equal 2, result[:clear_added_count]
    assert_equal 0, result[:blocked_added_count]
    assert_equal [[1, 2], [0, 2]], result[:added_edges].map { |r| r[:edge] }
    assert_equal [:clear, :clear], result[:added_edges].map { |r| r[:classification] }
    assert_equal 1, result[:component_count_after]
  end

  def test_blocked_edges_only_connect_components_remaining_after_clear_tier
    original = graph([node(0, 0), node(1, 0), node(5, 0), node(6, 0)],
                     [[0, 1], [2, 3]])
    result = Builder.build(original, los_batch: ->(pairs) { Array.new(pairs.size, false) })

    assert_equal [[0, 1], [2, 3]], result[:edges].first(2)
    assert_equal [[1, 2]], result[:added_edges].map { |r| r[:edge] }
    assert_equal 0, result[:clear_added_count]
    assert_equal 1, result[:blocked_added_count]
    assert_equal false, result[:added_edges].first[:los_clear]
    assert_equal 1, result[:component_count_after]
  end

  def test_never_add_redundant_cycle_or_replace_optimized_edges
    original = graph([node(0, 0), node(1, 0), node(2, 0), node(3, 0)],
                     [[0, 1]])
    result = Builder.build(original, los_batch: ->(pairs) { Array.new(pairs.size, true) })

    assert_equal 3, result[:component_count_before]
    assert_equal 2, result[:added_edges].size
    assert_equal 3, result[:edges].size
    assert_equal 1, result[:component_count_after]
  end

  def test_strict_native_result_validation_never_falls_back_to_blocked
    original = graph([node(0, 0), node(1, 0)])
    assert_raises(ArgumentError) { Builder.build(original, los_batch: ->(_pairs) { [] }) }
    assert_raises(ArgumentError) { Builder.build(original, los_batch: ->(_pairs) { [nil] }) }
    assert_raises(RuntimeError) { Builder.build(original, los_batch: ->(_pairs) { raise 'Native failure' }) }
  end

  def test_large_floor_graph_connects_without_allocating_all_pairs
    # Synthetic centroids from a long tessellated floor, with State at 0.
    count = Builder::MAX_EXHAUSTIVE_NODES + 1
    original = graph(Array.new(count) { |i| node(i * 0.3, 0, i * 0.01) })
    batches = []
    connected = Builder.build(original, los_batch: lambda { |pairs|
      batches << pairs.size
      Array.new(pairs.size, true)
    })

    assert_equal 1, connected[:component_count_after]
    assert_equal count - 1, connected[:clear_added_count]
    assert_equal 0, connected[:blocked_added_count]
    assert_equal count - 1, connected[:edges].length
    assert_operator connected[:checked_pairs], :<, count * (count - 1) / 2
    assert batches.all? { |size| size <= Builder::MAX_PAIRS_PER_BATCH }
    assert_equal original[:nodes], connected[:nodes]
  end

  def test_large_floor_graph_never_calls_blocked_edge_clear
    count = Builder::MAX_EXHAUSTIVE_NODES + 1
    original = graph(Array.new(count) { |i| node(i, 0) })
    connected = Builder.build(original, los_batch: lambda { |pairs|
      Array.new(pairs.size, false)
    })

    assert_equal 1, connected[:component_count_after]
    assert_equal 0, connected[:clear_added_count]
    assert_equal count - 1, connected[:blocked_added_count]
    assert connected[:added_edges].all? { |record|
      record[:classification] == :blocked && record[:los_clear] == false
    }
  end

  def test_state_origin_and_node_limit_checked
    invalid = graph([node(0, 0), node(1, 0)]).merge(original_indices: [3, 4])
    assert_raises(ArgumentError) do
      Builder.build(invalid, los_batch: ->(_pairs) { flunk })
    end

    oversized = graph(Array.new(Builder::MAX_NODES + 1) { |i| node(i, 0) })
    assert_raises(ArgumentError) do
      Builder.build(oversized, los_batch: ->(_pairs) { flunk })
    end
  end

  def test_same_components_not_queried_or_added
    original = graph([node(0, 0), node(1, 0), node(9, 0), node(10, 0)],
                     [[0, 1], [2, 3]])
    calls = []
    result = Builder.build(original, los_batch: lambda { |pairs|
      calls.concat(pairs.map { |a, b| [a.x, b.x] })
      Array.new(pairs.size, false)
    })
    assert_equal 4, result[:checked_pairs]
    refute_includes calls, [0.0, 1.0]
    refute_includes calls, [9.0, 10.0]
  end

  def test_all_los_results_arrive_in_bounded_batches
    original = graph(Array.new(70) { |i| node(i, 0) })
    batches = []
    result = Builder.build(original, los_batch: lambda { |pairs|
      batches << pairs.size
      Array.new(pairs.size, false)
    })
    assert_equal [2048, 367], batches
    assert_equal 2415, result[:checked_pairs]
    assert_equal 69, result[:added_edges].size
    assert_equal 69, result[:blocked_added_count]
  end
end
