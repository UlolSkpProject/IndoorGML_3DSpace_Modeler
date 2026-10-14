# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_loop_collapser'
require_relative '../indoor3d/application/adjacency_service/reference_graph_debug_mode'

class ReferenceGraphLoopCollapserTest < Minitest::Test
  Collapse = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphLoopCollapser
  Mode = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode
  Point = Struct.new(:x, :y, :z)

  def n(x, y, radius = 1)
    { point: Point.new(x.to_f, y.to_f, 0.5), radius: radius.to_f }.freeze
  end

  def graph(nodes, edges)
    { nodes: nodes.freeze, edges: edges.map(&:freeze).freeze,
      original_indices: (0...nodes.length).to_a.freeze }.freeze
  end

  def verified(triple, point, neighbors)
    { triangle: triple.freeze, point: point, radius: 1.0,
      visible_neighbors: neighbors.freeze }.freeze
  end

  def test_new_point_replaces_triangle_without_changing_original_graph
    original = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(1, 2)],
      [[1, 2], [1, 3], [2, 3]]
    )
    candidate = verified([1, 2, 3], Point.new(1, 2.0 / 3, 0.5), [])
    reduced = Collapse.collapse(original, [candidate])

    assert_equal 2, reduced[:nodes].size
    assert_equal 0, reduced[:nodes][0][:point].x - 10
    assert_nil reduced[:original_indices].last
    assert_equal 1, reduced[:collapse_count]
    assert_equal 0, reduced[:edges].length
    assert_equal 4, original[:nodes].size
    assert_equal 3, original[:edges].size
  end

  def test_native_visibility_is_required_for_every_external_connection
    source = graph(
      [n(0, 1), n(2, 0), n(3, 1), n(2, 2), n(4, 1)],
      [[0, 1], [1, 2], [1, 3], [2, 3], [2, 4], [3, 4]]
    )
    invalid = verified([1, 2, 3], Point.new(2.33, 1, 0.5), [0])
    assert_equal 0, Collapse.collapse(source, [invalid])[:collapse_count]

    valid = verified([1, 2, 3], Point.new(2.33, 1, 0.5), [0, 4])
    result = Collapse.collapse(source, [valid])
    assert_equal 1, result[:collapse_count]
    assert_equal [0, 4, nil], result[:original_indices]
    assert_equal 2, result[:edges].length
  end

  def test_native_verified_center_can_collapse_despite_large_detour
    source = graph(
      [n(10, 10), n(0, 0), n(3, 0), n(0, 3),
       n(2.99, 0.0), n(3.01, 0.0)],
      [[1, 2], [1, 3], [2, 3], [2, 4], [2, 5]]
    )
    center = verified([1, 2, 3], Point.new(1.0, 1.0, 0.5), [4, 5])
    result = Collapse.collapse(source, [center])

    # The detour exceeds the former 25% limit, but the candidate is
    # validated and its external links are preserved.
    assert_equal 1, result[:collapse_count]
    assert_equal 4, result[:nodes].size
    assert_equal [0, 4, 5, nil], result[:original_indices]
    assert_equal [[1, 3], [2, 3]], result[:edges]
    assert_equal 6, source[:nodes].size
    assert_equal 5, source[:edges].size
  end

  def test_state_in_triangle_is_preserved_as_representative
    source = graph(
      [n(0, 0), n(1, 0), n(0.5, 0.4), n(0, 1)],
      [[0, 1], [0, 2], [1, 2], [0, 3], [1, 3]]
    )
    # A State cycle must now receive an explicit hole-free verification
    # from Native; it must never bypass the geometry topology guard.
    without_native = Collapse.collapse(source, [])
    assert_equal 0, without_native[:collapse_count]
    assert_equal source[:edges], without_native[:edges]

    checked = verified([0, 1, 2], source[:nodes][0][:point], [])
    result = Collapse.collapse(source, [checked])

    assert_equal 1, result[:collapse_count]
    assert_equal [0, 3], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
    assert_same source[:nodes][0], result[:nodes][0]
  end

  def test_graph_without_native_candidates_does_not_invent_new_points
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(1, 2)],
      [[1, 2], [1, 3], [2, 3]]
    )
    assert_equal 0, Collapse.collapse(source, [])[:collapse_count]
  end

  def test_deferred_collapse_of_four_cycle
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(2, 2), n(0, 2)],
      [[1, 2], [2, 3], [3, 4], [1, 4]]
    )
    candidate = { vertices: [1, 2, 3, 4],
                  point: Point.new(1, 1, 0.5),
                  radius: 1.0,
                  visible_neighbors: [] }
    result = Collapse.collapse(source, [candidate])

    assert_equal 1, result[:collapse_count]
    assert_equal 1, result[:loop_count]
    assert_equal [0, nil], result[:original_indices]
    assert_empty result[:edges]
    assert_equal 5, source[:nodes].size
  end

  def test_five_cycle_preserves_all_external_neighbors
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(3, 1), n(1.5, 3), n(-0.5, 1), n(4, 1)],
      [[1, 2], [2, 3], [3, 4], [4, 5], [1, 5], [3, 6]]
    )
    candidate = { vertices: [1, 2, 3, 4, 5],
                  point: Point.new(1.2, 1.2, 0.5),
                  radius: 1.0,
                  visible_neighbors: [6] }
    result = Collapse.collapse(source, [candidate])

    assert_equal 1, result[:collapse_count]
    assert_equal [0, 6, nil], result[:original_indices]
    assert_equal [[1, 2]], result[:edges]
    assert_equal 7, source[:nodes].size
  end

  def test_chorded_four_cycle_is_not_minimal
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(2, 2), n(0, 2)],
      [[1, 2], [2, 3], [3, 4], [1, 4], [1, 3]]
    )
    candidate = { vertices: [1, 2, 3, 4],
                  point: Point.new(1, 1, 0.5),
                  radius: 1.0,
                  visible_neighbors: [] }
    result = Collapse.collapse(source, [candidate])

    assert_equal 0, result[:collapse_count]
    assert_equal [0, 1, 2, 3, 4], result[:original_indices]
    assert_equal 2, result[:loop_count] # two smaller triangles
  end

  def test_console_has_six_modes
    output, = capture_io do
      assert_equal :before, Mode.before!
      assert_equal :after, Mode.after!
      assert_equal :collapsed, Mode.collapsed!
      assert Mode.collapsed?
      assert_equal :optimized, Mode.optimized!
      assert Mode.optimized?
      assert_equal :internal, Mode.internal!
      assert Mode.internal?
      assert_equal :connected, Mode.connected!
      assert Mode.connected?
      assert_equal :before, Mode.before!
    end
    assert_includes output, 'COLLAPSED'
    assert_includes output, 'OPTIMIZED'
    assert_includes output, 'INTERNAL'
    assert_includes output, 'CONNECTED'
  end
  def test_deferred_batch_collapses_two_disjoint_triangles_simultaneously
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(1, 2),
       n(5, 0), n(7, 0), n(6, 2)],
      [[1, 2], [1, 3], [2, 3],
       [4, 5], [4, 6], [5, 6]]
    )
    candidates = [
      verified([1, 2, 3], Point.new(1, 0.67, 0.5), []),
      verified([4, 5, 6], Point.new(6, 0.67, 0.5), [])
    ]

    result = Collapse.collapse(source, candidates)

    assert_equal 2, result[:collapse_count]
    assert_equal 2, result[:triangle_count]
    assert_equal 2, result[:eligible_count]
    assert_equal [0, nil, nil], result[:original_indices]
    assert_empty result[:edges]
    assert_equal 3, result[:nodes].length
    assert_equal 7, source[:nodes].length
    assert_equal 6, source[:edges].length
  end

  def test_shared_vertex_loops_cannot_be_collapsed_in_same_batch
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(1, 1), n(3, 1)],
      [[1, 2], [1, 3], [2, 3], [2, 4], [3, 4]]
    )
    candidates = [
      verified([1, 2, 3], Point.new(1, 0.33, 0.5), [4]),
      verified([2, 3, 4], Point.new(2, 0.67, 0.5), [1])
    ]

    result = Collapse.collapse(source, candidates)

    assert_equal 1, result[:collapse_count]
    assert_equal 2, result[:eligible_count]
    assert_equal [0, 4, nil], result[:original_indices]
    assert_equal [[1, 2]], result[:edges]
    assert_equal 5, source[:nodes].length
    assert_equal 5, source[:edges].length
  end

  def test_disjoint_loops_with_cross_edge_require_unverified_center_to_center_los
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(1, 2),
       n(5, 0), n(7, 0), n(6, 2)],
      [[1, 2], [1, 3], [2, 3],
       [4, 5], [4, 6], [5, 6], [3, 4]]
    )
    candidates = [
      verified([1, 2, 3], Point.new(1, 0.67, 0.5), [4]),
      verified([4, 5, 6], Point.new(6, 0.67, 0.5), [3])
    ]

    result = Collapse.collapse(source, candidates)

    assert_equal 2, result[:eligible_count]
    assert_equal 1, result[:collapse_count]
    assert_equal [0, 4, 5, 6, nil], result[:original_indices]
    assert_equal [[1, 2], [1, 3], [1, 4], [2, 3]], result[:edges]
  end

  def test_batch_result_does_not_depend_on_native_candidate_order
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(1, 2),
       n(5, 0), n(7, 0), n(6, 2)],
      [[1, 2], [1, 3], [2, 3], [4, 5], [4, 6], [5, 6]]
    )
    candidates = [
      verified([1, 2, 3], Point.new(1, 0.67, 0.5), []),
      verified([4, 5, 6], Point.new(6, 0.67, 0.5), [])
    ]

    first = Collapse.collapse(source, candidates)
    second = Collapse.collapse(source, candidates.reverse)

    assert_equal first, second
    assert_equal 2, first[:collapse_count]
  end

  def test_prevalidated_collapse_candidate_does_not_depend_on_circle_radius
    source = graph(
      [n(10, 10), n(0, 0), n(2, 0), n(1, 2)],
      [[1, 2], [1, 3], [2, 3]]
    )
    candidate = verified([1, 2, 3], Point.new(1, 2.0 / 3, 0.5), []).merge(radius: 0.0)
    result = Collapse.collapse(source, [candidate])

    assert_equal 1, result[:collapse_count]
    assert_equal [0, nil], result[:original_indices]
  end

  def test_state_loop_without_hole_free_native_certificate_is_never_collapsed
    source = graph(
      [n(0, 0), n(2, 0), n(1, 2), n(4, 0)],
      [[0, 1], [0, 2], [1, 2], [0, 3], [1, 3]]
    )
    result = Collapse.collapse(source, [])

    assert_equal 0, result[:collapse_count]
    assert_equal 2, result[:loop_count]
    assert_equal source[:edges], result[:edges]
    assert_equal source[:nodes], result[:nodes]
  end

  def test_native_hole_rejection_does_not_invent_loop_representative
    source = graph(
      [n(5, 5), n(0, 0), n(4, 0), n(4, 4), n(0, 4)],
      [[1, 2], [2, 3], [3, 4], [1, 4]]
    )
    # No Native candidate is present when a wall slice lies inside the
    # 4-cycle. The original disconnected graph must remain unchanged.
    result = Collapse.collapse(source, [])

    assert_equal 0, result[:collapse_count]
    assert_equal 1, result[:loop_count]
    assert_equal source[:nodes], result[:nodes]
    assert_equal source[:edges], result[:edges]
  end

end
