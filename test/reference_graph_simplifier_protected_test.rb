# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_simplifier'

class ReferenceGraphSimplifierProtectedTest < Minitest::Test
  Simplify = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphSimplifier
  Point = Struct.new(:x, :y, :z)

  def n(x, y, radius)
    { point: Point.new(x.to_f, y.to_f, 5.0), radius: radius.to_f }.freeze
  end

  def source(nodes, edges, certs = [])
    { nodes: nodes.freeze, edges: edges.map(&:freeze).freeze,
      loop_candidates: certs.freeze }.freeze
  end

  def test_certified_ring_and_all_gateways_are_protected
    graph = source(
      [n(0, 0, 5), n(1, 1, 0.5), n(2, 1, 0.5), n(1.5, 2, 0.5),
       n(3, 2, 0.5), n(0.3, 0.3, 0.5)],
      [[0, 1], [0, 5], [1, 2], [2, 3], [1, 3], [3, 4], [0, 4], [4, 5]],
      [{ vertices: [1, 2, 3], point: Point.new(1.5, 1.5, 5),
         radius: 0.4, visible_neighbors: [0, 4] }]
    )
    before_nodes = graph[:nodes].dup
    result = Simplify.simplify(graph, los_batch: ->(_pairs) { [true] })
    [0, 1, 2, 3, 4].each do |index|
      assert_includes result[:original_indices], index,
                      "Certificate ring/gateway #{index} was modified in AFTER"
    end
    assert_equal before_nodes, graph[:nodes]
    assert_equal [[1, 2], [1, 3], [2, 3]], graph[:edges].select { |a, b| [1,2,3].include?(a) && [1,2,3].include?(b) }.sort
  end

  def test_only_simultaneously_selectable_loops_expand_protection
    graph = source(
      [n(50, 50, 5), n(0, 0, 1), n(2, 0, 1), n(1, 2, 1),
       n(10, 0, 1), n(14, 0, 1), n(12, 4, 1), n(18, 4, 1)],
      [[1, 2], [1, 3], [2, 3], [3, 4],
       [4, 5], [4, 6], [5, 6], [6, 7]],
      [
        { vertices: [1, 2, 3], point: Point.new(1, 0.7, 5),
          radius: 0.5, visible_neighbors: [4] },
        { vertices: [4, 5, 6], point: Point.new(12, 1.3, 5),
          radius: 0.5, visible_neighbors: [3, 7] }
      ]
    )

    # The cross-edge 3-4 prevents both representatives from being created
    # without a new representative-to-representative LOS. The smaller first
    # loop is selected, so protect its ring and gateway 4, but do not let the
    # rejected second certificate extend protection through 5, 6 and 7.
    assert_equal [0, 1, 2, 3, 4], Simplify.protected_originals(graph, [])
  end

  def test_compact_cluster_uses_shared_contraction_and_keeps_original
    graph = source(
      [n(0, 0, 5), n(0.5, 0, 0.5), n(0, 0.6, 0.5), n(0.8, 0.6, 0.5)],
      [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]]
    )
    result = Simplify.simplify(graph)
    assert_equal [0, 3], result[:original_indices]
    assert_equal [[1, 0], [2, 0]], result[:merged_into]
    assert_equal [[0, 1]], result[:edges]
    assert_equal 4, graph[:nodes].size
    assert result[:nodes].frozen?
  end

  def test_external_native_los_is_batched_and_failure_rejects_entire_cluster
    graph = source(
      [n(0, 0, 5), n(0.3, 0, 0.6), n(0, 0.3, 0.6),
       n(0.6, 0.3, 0.5), n(0.8, 0.4, 0.5)],
      [[0, 1], [0, 2], [1, 2], [1, 3], [3, 4], [2, 4]]
    )
    calls = []
    blocked = Simplify.simplify(graph, los_batch: lambda { |pairs|
      calls << pairs
      Array.new(pairs.length, false)
    })
    assert calls.any? { |pairs| pairs.length >= 1 }
    assert_equal [0, 1, 2, 3, 4], blocked[:original_indices]
    assert_equal graph[:edges], blocked[:edges]

    clear = Simplify.simplify(graph, los_batch: ->(pairs) { Array.new(pairs.length, true) })
    assert_operator clear[:nodes].length, :<, graph[:nodes].length
    assert_equal 0, clear[:original_indices].first
  end

  def test_chain_without_common_neighbor_requires_native_los
    graph = source(
      [n(0, 0, 5), n(1, 0, 1), n(2, 0, 1), n(3, 0, 1)],
      [[0, 1], [1, 2], [2, 3]]
    )
    original_edges = graph[:edges]

    no_native = Simplify.simplify(graph)
    assert_equal [0, 1, 2, 3], no_native[:original_indices]
    assert_equal original_edges, no_native[:edges]

    blocked = Simplify.simplify(graph, los_batch: ->(pairs) { Array.new(pairs.length, false) })
    assert_equal [0, 1, 2, 3], blocked[:original_indices]
    assert_equal original_edges, blocked[:edges]

    calls = []
    accepted = Simplify.simplify(graph, los_batch: lambda { |pairs|
      calls.concat(pairs)
      Array.new(pairs.length, true)
    })
    assert_equal [0, 2, 3], accepted[:original_indices]
    assert_equal [[0, 1], [1, 2]], accepted[:edges]
    assert_equal [[1, 0]], accepted[:merged_into]
    assert_equal [[0.0, 2.0]], calls.map { |a, b| [a.x, b.x] }
    assert_equal original_edges, graph[:edges]
  end

  def test_native_los_exception_rejects_new_chain_edge_without_mutating_input
    graph = source(
      [n(0, 0, 5), n(1, 0, 1), n(2, 0, 1), n(3, 0, 1)],
      [[0, 1], [1, 2], [2, 3]]
    )
    result = Simplify.simplify(graph, los_batch: ->(*) { raise 'native error' })
    assert_equal [0, 1, 2, 3], result[:original_indices]
    assert_equal graph[:edges], result[:edges]
    assert_empty result[:merged_into]
    assert_equal [[0, 1], [1, 2], [2, 3]], graph[:edges]
  end

  def test_meaningful_degree_four_junction_is_not_absorbed
    graph = source(
      [n(0, 0, 5), n(0.4, 0, 1), n(0.6, 0, 0.2),
       n(0.6, 0.2, 0.2), n(0.6, -0.2, 0.2)],
      [[0, 1], [1, 2], [1, 3], [1, 4]]
    )
    result = Simplify.simplify(graph, los_batch: ->(pairs) { Array.new(pairs.length, true) })
    assert_equal [0, 1, 2, 3, 4], result[:original_indices]
    assert_equal graph[:edges], result[:edges]
    assert_empty result[:merged_into]
  end

  def test_semantic_door_and_transition_are_never_absorbed
    nodes = [n(0, 0, 5), n(0.3, 0, 0.5).merge(semantic_role: :door),
             n(0, 0.3, 0.5), n(0.2, 0.3, 0.5)]
    graph = source(nodes, [[0,1],[0,2],[0,3],[1,2],[1,3],[2,3]])
    result = Simplify.simplify(graph)
    assert_includes result[:original_indices], 1
  end
end
