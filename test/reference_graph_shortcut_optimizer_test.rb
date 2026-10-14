# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_shortcut_optimizer'

class ReferenceGraphShortcutOptimizerTest < Minitest::Test
  Optimizer = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphShortcutOptimizer
  Point = Struct.new(:x, :y, :z)

  def node(x, y)
    { point: Point.new(x.to_f, y.to_f, 0.5), radius: 0.0 }.freeze
  end

  def graph(nodes, edges, origins = nil)
    { nodes: nodes.freeze, edges: edges.map(&:freeze).freeze,
      original_indices: (origins || (0...nodes.size).to_a).freeze,
      collapse_count: 1 }.freeze
  end

  def test_existing_native_edge_is_safe_without_query
    original = graph([node(9, 9), node(0, 0), node(1, 0), node(2, 0)],
                     [[1, 2], [2, 3], [1, 3]])
    result = Optimizer.optimize(original)
    assert_equal [0, 1, 3], result[:original_indices]
    assert_equal [[1, 2]], result[:edges]
    assert_equal [], result[:shortcut_native_los_edges]
    assert_equal [2], result[:shortcut_removed_indices]
    assert_equal 3, original[:edges].size
  end

  def test_no_query_does_not_invent_unvalidated_edge
    original = graph([node(9, 9), node(0, 0), node(1, 0), node(2, 0)],
                     [[1, 2], [2, 3]])
    result = Optimizer.optimize(original)
    assert_equal 0, result[:shortcut_removed_count]
    assert_equal original[:edges], result[:edges]
  end

  def test_successful_native_los_allows_missing_direct_edge
    original = graph([node(9, 9), node(0, 0), node(1, 0), node(2, 0)],
                     [[1, 2], [2, 3]], [0, 8, nil, 10])
    calls = []
    validator = lambda do |a, c|
      calls << [a.x, c.x]
      true
    end
    result = Optimizer.optimize(original, los_validator: validator)
    assert_equal [[0.0, 2.0]], calls
    assert_equal [0, 8, 10], result[:original_indices]
    assert_equal [[1, 2]], result[:edges]
    assert_equal [[1, 2]], result[:shortcut_native_los_edges]
    assert_equal 1, result[:shortcut_removed_count]
    assert_equal 1, result[:collapse_count]
    assert_equal [0, 8, nil, 10], original[:original_indices]
  end

  def test_native_los_rejection_keeps_winding_corridor
    original = graph([node(9, 9), node(0, 0), node(1, 20), node(2, 0)],
                     [[1, 2], [2, 3]])
    result = Optimizer.optimize(original, los_validator: ->(_a, _c) { false })
    assert_equal 0, result[:shortcut_removed_count]
    assert_equal original[:edges], result[:edges]
  end

  def test_large_deviation_not_filtered_when_los_passes
    original = graph([node(9, 9), node(0, 0), node(1, 20), node(2, 0)],
                     [[1, 2], [2, 3]])
    result = Optimizer.optimize(original, los_validator: ->(_a, _c) { true })
    assert_equal 1, result[:shortcut_removed_count]
    assert_equal [[1, 2]], result[:shortcut_native_los_edges]
  end

  def test_state_never_removed_even_when_degree_two
    original = graph([node(1, 0), node(0, 0), node(2, 0)],
                     [[0, 1], [0, 2]])
    assert_equal 0, Optimizer.optimize(original, los_validator: ->(*) { true })[:shortcut_removed_count]
  end

  def test_branch_endpoints_and_isolated_node_are_protected
    original = graph([node(1, 0), node(0, 0), node(2, 0), node(1, 1)],
                     [[0, 1], [0, 2], [1, 2], [0, 3], [1, 3]])
    assert_equal 0, Optimizer.optimize(original, los_validator: ->(*) { true })[:shortcut_removed_count]
  end

  def test_projection_outside_segment_keeps_candidate
    assert_equal false, Optimizer.projected_between?(
      node(0, 0)[:point], node(3, 0)[:point], node(2, 0)[:point]
    )
  end

  def test_iterative_two_step_requires_second_segment_los
    original = graph(
      [node(9, 9), node(0, 0), node(1, 0), node(2, 0), node(3, 0)],
      [[1, 2], [2, 3], [3, 4]]
    )
    checked = []
    result = Optimizer.optimize(original, los_validator: lambda { |a, c|
      checked << [a.x, c.x]
      checked.size == 1
    })
    assert_equal 1, result[:shortcut_removed_count]
    assert_equal [[0.0, 2.0], [0.0, 3.0]], checked
    assert_equal [0, 1, 3, 4], result[:original_indices]
    assert_equal [[1, 2], [2, 3]], result[:edges]
  end
end
