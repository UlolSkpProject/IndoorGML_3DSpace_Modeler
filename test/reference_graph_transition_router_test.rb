# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_transition_router'

class ReferenceGraphTransitionRouterTest < Minitest::Test
  Router = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphTransitionRouter
  Point = Struct.new(:x, :y, :z)

  def node(x, y = 0, z = 0)
    { point: Point.new(x.to_f, y.to_f, z.to_f) }
  end

  def graph(nodes, edges, weights: nil, added: nil, original_count: nil, metadata: nil)
    result = { nodes: nodes, edges: edges }
    result[:edge_weights] = weights unless weights.nil?
    result[:original_edge_count] = original_count unless original_count.nil?
    result[:added_edges] = added unless added.nil?
    result[:edge_metadata] = metadata unless metadata.nil?
    result
  end

  def coordinates(route)
    route.map { |point| [point.x, point.y, point.z] }
  end

  def test_chain_shortest_path_to_gateway
    source = graph([node(0), node(1), node(2)], [[0, 1], [1, 2]])
    assert_equal [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [2.0, 0.0, 0.0]],
                 coordinates(Router.route(source, 0, Point.new(2.1, 0, 0)))
  end

  def test_gateway_is_closest_reachable_node_not_closest_isolated_node
    source = graph([node(0), node(3), node(10)], [[0, 1]])
    assert_equal [0.0, 3.0],
                 Router.route(source, 0, Point.new(10, 0, 0)).map(&:x)
  end

  def test_blocked_diagnostic_edge_is_not_routed
    source = graph([node(0), node(2), node(10)], [[0, 1], [1, 2]],
                   original_count: 1,
                   added: [{ edge: [1, 2], classification: :blocked, los_clear: false }])
    assert_equal [0.0, 2.0],
                 Router.route(source, 0, Point.new(10, 0, 0)).map(&:x)
  end

  def test_clear_los_edge_is_routed
    source = graph([node(0), node(2), node(10)], [[0, 1], [1, 2]],
                   original_count: 1,
                   added: [{ edge: [1, 2], classification: :clear, los_clear: true }])
    assert_equal [0.0, 2.0, 10.0],
                 Router.route(source, 0, Point.new(10, 0, 0)).map(&:x)
  end

  def test_blocked_or_unclear_edge_metadata_is_not_accepted
    source = graph([node(0), node(4)], [[0, 1]],
                   metadata: [{ classification: :blocked, los_clear: false }])
    assert_equal [0.0],
                 Router.route(source, 0, Point.new(4, 0, 0)).map(&:x)
    source[:edge_metadata] = [{ los_clear: false }]
    assert_equal [0.0],
                 Router.route(source, 0, Point.new(4, 0, 0)).map(&:x)
  end

  def test_native_shortcut_edge_metadata_remains_navigable
    source = graph([node(0), node(4)], [[0, 1]],
                   metadata: [{ source: :native_los }])
    assert_equal [0.0, 4.0],
                 Router.route(source, 0, Point.new(4, 0, 0)).map(&:x)
  end

  def test_invalid_indices_and_invalid_numeric_weights_are_rejected
    source = graph([node(0), node(3)], [[0, 9], [0, 1]],
                   weights: [1.0, Float::NAN])
    assert_equal [0.0],
                 Router.route(source, 0, Point.new(3, 0, 0)).map(&:x)
    source[:edge_weights] = [1.0, -1.0]
    assert_equal [0.0],
                 Router.route(source, 0, Point.new(3, 0, 0)).map(&:x)
    source[:edge_weights] = [1.0, Float::INFINITY]
    assert_equal [0.0],
                 Router.route(source, 0, Point.new(3, 0, 0)).map(&:x)
  end

  def test_missing_weight_uses_euclidean_distance
    source = graph([node(0), node(1), node(3)], [[0, 1], [1, 2], [0, 2]],
                   weights: [nil, nil, 10.0])
    assert_equal [0.0, 1.0, 3.0],
                 Router.route(source, 0, Point.new(3, 0, 0)).map(&:x)
  end

  def test_state_index_is_not_assumed_to_be_zero
    source = graph([node(10), node(0), node(5)], [[0, 2], [1, 2]])
    assert_equal [0.0, 5.0, 10.0],
                 Router.route(source, 1, Point.new(10, 0, 0)).map(&:x)
  end

  def test_tied_gateways_prefer_lower_index
    source = graph([node(0), node(2, 1), node(2, -1)], [[0, 1], [0, 2]])
    assert_equal [1.0],
                 Router.route(source, 0, Point.new(2, 0, 0)).drop(1).map(&:y)
  end

  def test_equal_cost_paths_use_lower_index_predecessor
    source = graph(
      [node(0), node(1, 1), node(1, -1), node(2)],
      [[0, 1], [1, 3], [0, 2], [2, 3]], weights: [1, 1, 1, 1]
    )
    assert_equal [[0.0, 0.0, 0.0], [1.0, 1.0, 0.0], [2.0, 0.0, 0.0]],
                 coordinates(Router.route(source, 0, Point.new(2, 0, 0)))
  end

  def test_zero_weight_cycle_does_not_loop
    source = graph([node(0), node(1), node(2)], [[0, 1], [1, 2], [0, 2]],
                   weights: [0, 0, 0])
    # Lexicographic tie resolution prefers 0 -> 1 -> 2 to 0 -> 2.
    assert_equal [0.0, 1.0, 2.0],
                 Router.route(source, 0, Point.new(2, 0, 0)).map(&:x)
  end

  def test_inconsistent_addition_metadata_disables_graph_route
    source = graph([node(0), node(1)], [[0, 1]], original_count: 0,
                   added: [{ edge: [0, 1], classification: :blocked, los_clear: true }])
    assert_equal [0.0],
                 Router.route(source, 0, Point.new(1, 0, 0)).map(&:x)
    source[:added_edges] = []
    assert_nil Router.route(source, 0, Point.new(1, 0, 0))
  end
end
