# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_state_selector'

class ReferenceGraphStateSelectorTest < Minitest::Test
  Selector = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphStateSelector
  Point = Struct.new(:x, :y, :z)

  def node(x, y = 0, z = 0)
    { point: Point.new(x.to_f, y.to_f, z.to_f), radius: 1.0 }.freeze
  end

  def test_selects_surviving_reference_nearest_equal_weight_mean
    graph = { nodes: [node(0), node(4), node(5)].freeze }.freeze
    result = Selector.select(graph)

    assert_equal [3.0, 0.0, 0.0], result[:mean_point]
    assert_equal 1, result[:state_node_index]
    assert_same graph[:nodes][1][:point], result[:point]
    assert_equal 3, graph[:nodes].length
  end

  def test_equal_distance_uses_lower_optimized_node_index
    graph = { nodes: [node(0), node(2)].freeze }.freeze
    result = Selector.select(graph)

    assert_equal [1.0, 0.0, 0.0], result[:mean_point]
    assert_equal 0, result[:state_node_index]
  end

  def test_single_reference_becomes_state
    graph = { nodes: [node(7, 8, 9)].freeze }.freeze
    result = Selector.select(graph)

    assert_equal 0, result[:state_node_index]
    assert_equal [7.0, 8.0, 9.0], result[:mean_point]
  end

  def test_empty_or_non_finite_graph_is_rejected
    assert_raises(ArgumentError) { Selector.select(nodes: []) }
    assert_raises(ArgumentError) do
      Selector.select(nodes: [node(Float::NAN)])
    end
  end
end
