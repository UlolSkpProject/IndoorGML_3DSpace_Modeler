# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_simplifier'
require_relative '../indoor3d/application/adjacency_service/reference_graph_debug_mode'

class ReferenceGraphSimplifierTest < Minitest::Test
  Simplifier = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphSimplifier
  Mode = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode
  Point = Struct.new(:x, :y, :z)

  def node(x, y, radius)
    { point: Point.new(x.to_f, y.to_f, 0.5), radius: radius.to_f }.freeze
  end

  def graph(nodes, edges)
    { nodes: nodes.freeze, edges: edges.map(&:freeze).freeze }.freeze
  end

  def test_large_visible_state_absorbs_redundant_centers_but_preserves_endpoint
    source = graph(
      [node(0, 0, 5), node(0.5, 0, 0.5),
       node(0, 0.6, 0.5), node(0.8, 0.6, 0.5)],
      [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]]
    )

    result = Simplifier.simplify(source)

    assert_equal 4, source[:nodes].size, 'original snapshot must remain intact'
    assert_equal 6, source[:edges].size, 'original LOS graph must remain intact'
    assert_equal [0, 3], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
    assert_equal [[1, 0], [2, 0]], result[:merged_into]
    assert_same source[:nodes][0], result[:nodes][0]
    assert_same source[:nodes][3], result[:nodes][1]
  end

  def test_articulation_point_on_curved_corridor_cannot_be_removed
    # State A --- Corner B --- Corner C; no direct LOS A--C.
    source = graph(
      [node(0, 0, 3), node(1, 0, 0.5), node(2, 0, 1)],
      [[0, 1], [1, 2]]
    )

    result = Simplifier.simplify(source)

    assert_equal [0, 1, 2], result[:original_indices]
    assert_equal [[0, 1], [1, 2]], result[:edges]
    assert_empty result[:merged_into]
  end

  def test_long_local_detour_prevents_merging_even_with_all_los_edges
    # Candidate B is covered by State's disk, and every neighbor has LOS
    # to State, but replacing the short C--B--D route by C--State--D
    # would add >25% distance.
    source = graph(
      [node(1, 2, 2), node(1, 0, 0.1),
       node(0.5, 0, 0.3), node(1.5, 0, 0.3)],
      [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3]]
    )

    result = Simplifier.simplify(source)

    assert_equal [0, 1, 2, 3], result[:original_indices]
    assert_empty result[:merged_into]
  end

  def test_insufficient_disk_coverage_does_not_absorb_node
    source = graph(
      [node(0, 0, 0.5), node(1, 0, 0.2),
       node(1, 0.35, 0.2)],
      [[0, 1], [0, 2], [1, 2]]
    )

    result = Simplifier.simplify(source)

    assert_equal [0, 1, 2], result[:original_indices]
    assert_empty result[:merged_into]
  end

  def test_state_and_isolated_candidates_remain_present
    source = graph(
      [node(0, 0, 0.2), node(5, 0, 2), node(10, 0, 0.1)],
      []
    )

    result = Simplifier.simplify(source)

    assert_equal [0, 1, 2], result[:original_indices]
    assert_empty result[:edges]
  end

  def test_console_mode_switches_without_regenerating_any_graph
    output, = capture_io do
      assert_equal :after, Mode.after!
      assert Mode.after?
      assert_equal :before, Mode.before!
      refute Mode.after?
      assert_equal :before, Mode.mode
    end
    assert_includes output, 'AFTER'
    assert_includes output, 'BEFORE'
  end
end
