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

  def test_native_verified_center_still_rejected_if_global_detour_exceeds_25_percent
    source = graph(
      [n(10, 10), n(0, 0), n(3, 0), n(0, 3),
       n(2.99, 0.0), n(3.01, 0.0)],
      [[1, 2], [1, 3], [2, 3], [2, 4], [2, 5]]
    )
    center = verified([1, 2, 3], Point.new(1.0, 1.0, 0.5), [4, 5])
    result = Collapse.collapse(source, [center])

    assert_equal 0, result[:collapse_count]
    assert_equal 6, result[:nodes].size
  end

  def test_state_in_triangle_is_preserved_as_representative
    source = graph(
      [n(0, 0), n(1, 0), n(0.5, 0.4), n(0, 1)],
      [[0, 1], [0, 2], [1, 2], [0, 3], [1, 3]]
    )
    result = Collapse.collapse(source, [])

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

  def test_console_has_three_modes
    output, = capture_io do
      assert_equal :before, Mode.before!
      assert_equal :after, Mode.after!
      assert_equal :collapsed, Mode.collapsed!
      assert Mode.collapsed?
      assert_equal :before, Mode.before!
    end
    assert_includes output, 'COLLAPSED'
  end
end
