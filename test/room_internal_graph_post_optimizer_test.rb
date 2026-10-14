# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_shortcut_optimizer'
require_relative '../indoor3d/application/adjacency_service/room_internal_visibility_graph'
require_relative '../indoor3d/application/adjacency_service/room_internal_graph_post_optimizer'

class RoomInternalGraphPostOptimizerTest < Minitest::Test
  Post = ULOL::Indoor3DGmlModeler::IndoorCore::RoomInternalGraphPostOptimizer
  Point = Struct.new(:x, :y, :z)

  def node(x, y = 0)
    { point: Point.new(x.to_f, y.to_f, 0.5), radius: 0.0 }.freeze
  end

  def graph(nodes, original_edges, additions = [], origins = nil)
    added = additions.map do |pair, classification|
      a, b = pair
      {
        edge: [a, b].freeze,
        length: Math.hypot(nodes[a][:point].x - nodes[b][:point].x,
                           nodes[a][:point].y - nodes[b][:point].y),
        classification: classification,
        los_clear: classification == :clear
      }.freeze
    end
    edges = (original_edges + added.map { |x| x[:edge] }).map(&:freeze).freeze
    {
      nodes: nodes.freeze,
      edges: edges,
      original_indices: (origins || (0...nodes.size).to_a).freeze,
      original_edge_count: original_edges.length,
      added_edges: added.freeze,
      edge_weights: Array.new(edges.length, 1.0).freeze,
      clear_added_count: added.count { |x| x[:classification] == :clear },
      blocked_added_count: added.count { |x| x[:classification] == :blocked },
      component_count_before: 2,
      component_count_after: 1,
      checked_pairs: 6,
      source_stage: :optimized
    }.freeze
  end

  def test_one_more_shortcut_replaces_degree_two_with_verified_direct_edge
    input = graph([node(0), node(1), node(2)], [[0, 1], [1, 2]])
    queried = []
    result = Post.optimize(input, los_batch: lambda { |pairs|
      queried.concat(pairs.map { |a, b| [a.x, b.x] })
      [true]
    })

    assert_equal [[0.0, 2.0]], queried
    assert_equal [0, 2], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
    assert_equal [2.0], result[:edge_weights]
    assert_equal 0, result[:original_edge_count]
    assert_equal :clear, result[:added_edges][0][:classification]
    assert_equal :shortcut, result[:added_edges][0][:source]
    assert_equal 1, result[:postopt_removed_count]
    assert_equal [1], result[:postopt_removed_indices]
    assert_equal 1, result[:postopt_los_checked_pairs]
    assert_equal 3, input[:nodes].length
    assert_equal [[0, 1], [1, 2]], input[:edges]
  end

  def test_blocked_native_los_preserves_original_node_and_edges
    input = graph([node(0), node(1), node(2)], [[0, 1], [1, 2]])
    result = Post.optimize(input, los_batch: ->(_pairs) { [false] })

    assert_equal input[:nodes], result[:nodes]
    assert_equal input[:edges], result[:edges]
    assert_equal 0, result[:postopt_removed_count]
    assert_equal 1, result[:postopt_los_checked_pairs]
    assert_equal input[:original_edge_count], result[:original_edge_count]
  end

  def test_already_verified_direct_edge_needs_no_new_los
    input = graph([node(0), node(1), node(2)],
                  [[0, 1], [1, 2], [0, 2]])
    result = Post.optimize(input, los_batch: ->(_pairs) { flunk 'LOS not needed' })

    assert_equal [0, 2], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
    assert_equal 1, result[:original_edge_count]
    assert_empty result[:added_edges]
    assert_equal 0, result[:postopt_los_checked_pairs]
  end

  def test_existing_blocked_direct_edge_is_not_regarded_as_safe
    input = graph(
      [node(0), node(1), node(2)],
      [[0, 1], [1, 2]],
      [[[0, 2], :blocked]]
    )
    result = Post.optimize(input, los_batch: ->(_pairs) { flunk 'Known blocked LOS' })

    assert_equal input[:nodes], result[:nodes]
    assert_equal input[:edges], result[:edges]
    assert_equal [[0, 2]], result[:added_edges].map { |r| r[:edge] }
    assert_equal 1, result[:blocked_added_count]
  end

  def test_blocked_incident_edge_is_replaced_only_when_shortcut_is_clear
    input = graph(
      [node(0), node(1), node(2)],
      [[0, 1]],
      [[[1, 2], :blocked]]
    )
    result = Post.optimize(input, los_batch: ->(_pairs) { [true] })

    assert_equal [0, 2], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
    assert_equal 0, result[:original_edge_count]
    assert_equal 0, result[:blocked_added_count]
    assert_equal 1, result[:clear_added_count]
    assert_equal true, result[:added_edges][0][:los_clear]
    assert_equal :shortcut, result[:added_edges][0][:source]
    assert_equal 1, input[:blocked_added_count]
  end

  def test_state_degree_two_is_immutable
    input = graph([node(1), node(0), node(2)], [[0, 1], [0, 2]])
    result = Post.optimize(input, los_batch: ->(_pairs) { flunk 'State protected' })

    assert_equal input[:nodes], result[:nodes]
    assert_equal 0, result[:postopt_removed_count]
    assert_same input[:nodes][0], result[:nodes][0]
  end

  def test_branch_and_end_nodes_are_not_removed
    input = graph([node(0), node(1), node(2), node(3)],
                  [[0, 1], [1, 2], [1, 3]])
    result = Post.optimize(input, los_batch: ->(_pairs) { flunk 'No degree-2' })

    assert_equal 0, result[:postopt_removed_count]
    assert_equal 4, result[:nodes].length
  end

  def test_projection_outside_segment_keeps_middle
    input = graph([node(0), node(3), node(2)], [[0, 1], [1, 2]])
    result = Post.optimize(input, los_batch: ->(_pairs) { flunk 'Not between' })

    assert_equal 0, result[:postopt_removed_count]
  end

  def test_iterative_two_removals_recheck_neighbors_and_batch_los
    input = graph([node(0), node(1), node(2), node(3)],
                  [[0, 1], [1, 2], [2, 3]])
    calls = []
    result = Post.optimize(input, los_batch: lambda { |pairs|
      calls << pairs.map { |a, b| [a.x, b.x] }
      Array.new(pairs.length, true)
    })

    assert_equal [[[0.0, 2.0], [1.0, 3.0]], [[0.0, 3.0]]], calls
    assert_equal 2, result[:postopt_removed_count]
    assert_equal [1, 2], result[:postopt_removed_indices]
    assert_equal [0, 3], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
    assert_equal 3, result[:postopt_los_checked_pairs]
  end

  def test_native_failure_raises_without_mutating_kruskal_snapshot
    input = graph([node(0), node(1), node(2)], [[0, 1], [1, 2]])
    assert_raises(ArgumentError) do
      Post.optimize(input, los_batch: ->(_pairs) { [nil] })
    end
    assert_equal [[0, 1], [1, 2]], input[:edges]
    assert_equal 3, input[:nodes].length
  end

  def test_retained_kruskal_color_and_weight_mapping
    # The blue (LOS-clear) added edge is preserved after removing B;
    # no red or black edge is incorrectly invented.
    input = graph(
      [node(0), node(1), node(2), node(4)],
      [[0, 1], [1, 2]],
      [[[2, 3], :clear]]
    )
    result = Post.optimize(input, los_batch: lambda { |pairs|
      pairs.map { |a, b| a.x == 0.0 && b.x == 2.0 }
    })

    assert_equal [0, 2, 3], result[:original_indices]
    assert_equal 0, result[:original_edge_count]
    assert_equal [[1, 2], [0, 1]], result[:edges]
    assert_equal [:clear, :clear], result[:added_edges].map { |r| r[:classification] }
    assert_equal [:kruskal, :shortcut], result[:added_edges].map { |r| r[:source] }
    assert_equal [2.0, 2.0], result[:edge_weights]
    assert_equal 0, result[:blocked_added_count]
    assert_equal 1, result[:component_count_after]
    assert_equal 2, result[:component_count_before]
    assert_equal 6, result[:checked_pairs]
  end

  def test_bad_added_edge_metadata_is_not_silently_reclassified
    input = graph([node(0), node(1), node(2)], [[0, 1]], [[[1, 2], :blocked]])
    bad = input.merge(added_edges: input[:added_edges].map { |x| x.merge(los_clear: true) })
    assert_raises(ArgumentError) do
      Post.optimize(bad, los_batch: ->(_pairs) { flunk })
    end
  end
end
