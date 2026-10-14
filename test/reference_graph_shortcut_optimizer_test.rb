# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_shortcut_optimizer'

class ReferenceGraphShortcutOptimizerTest < Minitest::Test
  Optimizer = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphShortcutOptimizer
  Point = Struct.new(:x, :y, :z)

  def node(x, y, radius = 1.0)
    { point: Point.new(x.to_f, y.to_f, 0.5), radius: radius.to_f }.freeze
  end

  def graph(nodes, edges, origins = nil)
    { nodes: nodes.freeze, edges: edges.map(&:freeze).freeze,
      original_indices: (origins || (0...nodes.size).to_a).freeze,
      collapse_count: 1 }.freeze
  end

  def test_shortcut_uses_existing_native_edge_and_preserves_snapshot
    original = graph([node(9, 9), node(0, 0), node(1, 0), node(2, 0)],
                     [[1, 2], [2, 3], [1, 3]])
    result = Optimizer.optimize(original)

    assert_equal [0, 1, 3], result[:original_indices]
    assert_equal [[1, 2]], result[:edges]
    assert_equal 1, result[:shortcut_removed_count]
    assert_equal [2], result[:shortcut_removed_indices]
    assert_equal 1, result[:collapse_count]
    assert_equal 4, original[:nodes].size
    assert_equal 3, original[:edges].size
  end

  def test_missing_direct_edge_protects_intermediate_node
    original = graph([node(9, 9), node(0, 0), node(1, 0), node(2, 0)],
                     [[1, 2], [2, 3]])
    result = Optimizer.optimize(original)
    assert_equal 0, result[:shortcut_removed_count]
    assert_equal original[:edges], result[:edges]
  end

  def test_large_deviation_protects_bend
    original = graph([node(9, 9), node(0, 0), node(1, 0.8), node(2, 0)],
                     [[1, 2], [2, 3], [1, 3]])
    assert_equal 0, Optimizer.optimize(original)[:shortcut_removed_count]
  end

  def test_state_and_branch_are_immutable
    original = graph([node(1, 0), node(0, 0), node(2, 0), node(1, 1)],
                     [[0, 1], [0, 2], [1, 2], [0, 3], [1, 3]])
    result = Optimizer.optimize(original)
    assert_equal 0, result[:shortcut_removed_count]
    assert_same original[:nodes][0], result[:nodes][0]
  end

  def test_collapsed_representative_origin_is_preserved
    original = graph([node(9, 9), node(0, 0), node(1, 0), node(2, 0)],
                     [[1, 2], [2, 3], [1, 3]], [0, 8, nil, 10])
    result = Optimizer.optimize(original)
    assert_equal [0, 8, 10], result[:original_indices]
    assert_equal [0, 8, nil, 10], original[:original_indices]
  end

  def test_multiple_independent_shortcuts_use_no_synthetic_edge
    original = graph(
      [node(9, 9), node(0, 0), node(1, 0), node(2, 0),
       node(4, 0), node(5, 0), node(6, 0)],
      [[1, 2], [2, 3], [1, 3], [4, 5], [5, 6], [4, 6]]
    )
    result = Optimizer.optimize(original)
    assert_equal 2, result[:shortcut_removed_count]
    assert_equal [2, 5], result[:shortcut_removed_indices]
    assert_equal [0, 1, 3, 4, 6], result[:original_indices]
    assert_equal [[1, 2], [3, 4]], result[:edges]
  end

  def test_endpoints_and_isolated_reference_are_preserved
    original = graph([node(0, 0), node(1, 0), node(2, 0), node(10, 10)],
                     [[0, 1], [1, 2]])
    assert_equal 0, Optimizer.optimize(original)[:shortcut_removed_count]
  end
end
