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
    assert_equal source[:nodes][0][:point], result[:nodes][0][:point]
    refute_same source[:nodes][0][:point], result[:nodes][0][:point]
    assert_equal source[:nodes][3][:point], result[:nodes][1][:point]
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

  def test_local_detour_limit_no_longer_blocks_a_los_safe_contraction
    # B bridges the very short C-B-D path; replacing that detour through
    # State is much longer. All retained connections already exist.
    source = graph(
      [node(1, 1.5, 2), node(1, 0, 1),
       node(0.9, 0, 0.2), node(1.1, 0, 0.2)],
      [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3]]
    )

    result = Simplifier.simplify(source)

    assert_equal [0, 2, 3], result[:original_indices]
    assert_equal [[0, 1], [0, 2]], result[:edges]
    assert_equal [[1, 0]], result[:merged_into]
    assert_equal 5, source[:edges].size
  end

  def test_ab_distance_uses_larger_radius_instead_of_small_radius_times_1_5
    # d(A,B)=1.55 is beyond the old 1.5*min(3,1)=1.5 cutoff.
    # It still respects the separate cluster diameter cap of 1.6*1=1.6.
    source = graph(
      [node(0, 0, 3), node(1.55, 0, 1), node(3, 0, 0.1)],
      [[0, 1], [0, 2], [1, 2]]
    )
    result = Simplifier.simplify(source)
    assert_equal [0, 2], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
  end

  def test_ab_distance_is_strictly_less_than_larger_radius
    source = graph(
      [node(0, 0, 2), node(2, 0, 1.5), node(4, 0, 0.2)],
      [[0, 1], [0, 2], [1, 2]]
    )
    result = Simplifier.simplify(source)
    assert_equal [0, 1, 2], result[:original_indices]
    assert_empty result[:merged_into]
  end

  def test_cluster_diameter_cap_is_still_enforced
    source = graph(
      [node(0, 0, 10), node(1, 0, 0.1), node(2, 0, 0.1)],
      [[0, 1], [0, 2], [1, 2]]
    )
    result = Simplifier.simplify(source)
    assert_equal [0, 1, 2], result[:original_indices]
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

  def test_equal_xy_but_distant_z_is_not_absorbed_by_a_sphere
    source = graph(
      [node(0, 0, 5),
       { point: Point.new(0.0, 0.0, 8.0), radius: 0.2 },
       { point: Point.new(1.0, 0.0, 8.0), radius: 0.2 }],
      [[0, 1], [0, 2], [1, 2]]
    )

    result = Simplifier.simplify(source)

    assert_equal [0, 1, 2], result[:original_indices]
    assert_empty result[:merged_into]
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
