# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'collapsed_contract_fixture_test'
require_relative '../indoor3d/application/adjacency_service/reference_graph_loop_collapser'

class ReferenceGraphLoopCollapserTest < Minitest::Test
  include CollapsedContractFixture
  Collapse = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphLoopCollapser

  def isolated_triangle(ids = [1, 2, 3])
    raise ArgumentError unless ids == [1, 2, 3]
    graph([node(20, 20), node(0, 0), node(2, 0), node(1, 2)],
          [[1, 2], [1, 3], [2, 3]])
  end

  def triangle_cert(visible: [], p: point(1, 0.7), radius: 1.0)
    certificate([1, 2, 3], p, visible: visible, radius: radius)
  end

  def square_cert(ids = [1, 2, 3, 4], p: point(1, 1), visible: [])
    certificate(ids, p, visible: visible)
  end

  def test_no_native_certificate_never_contracts_even_if_cycle_is_obvious
    source = isolated_triangle
    result = Collapse.collapse(source, [])
    assert_equal 0, result[:collapse_count]
    assert_equal 0, result[:loop_count]
    assert_equal source[:original_indices], result[:original_indices]
    assert_equal source[:edges], result[:edges]
  end

  def test_hole_free_native_triangle_cert_creates_one_representative
    source = isolated_triangle
    result = Collapse.collapse(source, [triangle_cert])
    assert_equal 1, result[:collapse_count]
    assert_equal 1, result[:eligible_count]
    assert_equal [0, nil], result[:original_indices]
    assert_equal 2, result[:nodes].length
    assert_equal [], result[:edges]
    assert_equal point(1, 0.7), result[:nodes].last[:point]
    assert_equal 1.0, result[:nodes].last[:radius]
    assert_equal [[1, nil], [2, nil], [3, nil]], result[:merged_into]
    assert_equal 1, result[:contraction_history].length
    assert_equal 4, source[:nodes].length
  end

  def test_node_zero_triangle_is_replaced_by_certified_representative
    source = graph([node(0, 0), node(1, 0), node(0.5, 0.4), node(0, 1)],
                   [[0, 1], [0, 2], [1, 2], [0, 3], [1, 3]])
    cert = certificate([0, 1, 2], point(0, 0), visible: [3])
    result = Collapse.collapse(source, [cert])
    assert_equal 1, result[:collapse_count]
    assert_equal [3, nil], result[:original_indices]
    assert_equal [[0, 1]], result[:edges]
    assert_equal point(0, 0), result[:nodes][1][:point]
    assert_equal [[0, nil], [1, nil], [2, nil]], result[:merged_into]
    assert_equal 1, result[:contraction_history][0][:representative_index]
  end

  def test_node_zero_ring_is_replaced_by_certificate_center
    source = graph([node(0, 0), node(1, 0), node(1, 1), node(0, 1)],
                   [[0, 1], [1, 2], [2, 3], [0, 3]])
    fake = certificate([0, 1, 2, 3], point(0.5, 0.5))
    result = Collapse.collapse(source, [fake])
    assert_equal 1, result[:collapse_count]
    assert_equal [nil], result[:original_indices]
    assert_equal point(0.5, 0.5), result[:nodes][0][:point]
  end

  def test_closed_four_cycle_uses_native_certificate_without_extra_los
    source = graph([node(0, 0), node(2, 0), node(2, 2), node(0, 2)],
                   [[0, 1], [1, 2], [2, 3], [0, 3]])
    cert = certificate([0, 1, 2, 3], point(0, 0))
    accepted = Collapse.collapse(source, [cert])
    assert_equal 1, accepted[:collapse_count]
    assert_equal [nil], accepted[:original_indices]
    native_calls = []
    permit = Collapse.collapse(source, [cert], los_validator: lambda { |a, b|
      native_calls << [a, b]
      true
    })
    assert_equal 1, permit[:collapse_count]
    assert_equal [nil], permit[:original_indices]
    assert_empty native_calls
  end

  def test_missing_loop_member_in_after_rejects_original_native_certificate
    source = graph([node(20, 20), node(0, 0), node(1, 2)],
                   [[1, 2]], origins: [0, 1, 3], merges: [[2, 1]])
    result = Collapse.collapse(source, [triangle_cert])
    assert_equal 0, result[:collapse_count]
    assert_equal [0, 1, 3], result[:original_indices]
    assert_equal [[2, 1]], result[:merged_into]
  end

  def test_reindexed_after_original_ids_map_exact_native_cycle
    source = graph([node(20, 20), node(0, 0), node(2, 0), node(1, 2)],
                   [[1, 2], [1, 3], [2, 3]], origins: [0, 7, 12, 15])
    cert = certificate([7, 12, 15], point(1, 0.7))
    result = Collapse.collapse(source, [cert])
    assert_equal 1, result[:collapse_count]
    assert_equal [0, nil], result[:original_indices]
    assert_equal [[7, nil], [12, nil], [15, nil]], result[:merged_into]
  end

  def test_chorded_four_cycle_collapses_with_native_certificate
    source = graph([node(20, 20), node(0, 0), node(2, 0), node(2, 2), node(0, 2)],
                   [[1, 2], [2, 3], [3, 4], [1, 4], [1, 3]])
    result = Collapse.collapse(source, [square_cert])
    assert_equal 1, result[:collapse_count]
    assert_equal 1, result[:loop_count]
    assert_equal [0, nil], result[:original_indices]
    assert_empty result[:edges]
  end

  def test_missing_cycle_edge_rejects_certificate
    source = graph([node(20, 20), node(0, 0), node(2, 0), node(2, 2), node(0, 2)],
                   [[1, 2], [2, 3], [3, 4]])
    result = Collapse.collapse(source, [square_cert])
    assert_equal 0, result[:collapse_count]
    assert_equal source[:edges], result[:edges]
  end

  def test_overlap_conflict_selects_smaller_then_original_ids
    source = graph([node(20, 20), node(0, 0), node(2, 0), node(1, 1), node(3, 1)],
                   [[1, 2], [1, 3], [2, 3], [2, 4], [3, 4]])
    a = certificate([1, 2, 3], point(1, 0.35), visible: [4])
    b = certificate([2, 3, 4], point(2, 0.7), visible: [1])
    first = Collapse.collapse(source, [a, b])
    second = Collapse.collapse(source, [b, a])
    assert_equal first, second
    assert_equal 2, first[:eligible_count]
    assert_equal 1, first[:collapse_count]
    assert_equal [0, 4, nil], first[:original_indices]
    assert_equal 1, first[:rejected_count]
  end

  def test_cross_edge_between_removed_sets_blocks_simultaneous_collapse
    source = graph(
      [node(20, 20), node(0, 0), node(2, 0), node(1, 2),
       node(5, 0), node(7, 0), node(6, 2)],
      [[1, 2], [1, 3], [2, 3], [4, 5], [4, 6], [5, 6], [3, 4]]
    )
    a = certificate([1, 2, 3], point(1, 0.7), visible: [4])
    b = certificate([4, 5, 6], point(6, 0.7), visible: [3])
    result = Collapse.collapse(source, [b, a])
    assert_equal 2, result[:eligible_count]
    assert_equal 1, result[:collapse_count]
    assert_equal [0, 4, 5, 6, nil], result[:original_indices]
    assert_equal [[1, 2], [1, 3], [1, 4], [2, 3]], result[:edges]
  end

  def test_independent_disjoint_cycles_use_fresh_indices_between_contractions
    source = graph(
      [node(20, 20), node(0, 0), node(2, 0), node(1, 2),
       node(5, 0), node(7, 0), node(6, 2)],
      [[1, 2], [1, 3], [2, 3], [4, 5], [4, 6], [5, 6]]
    )
    a = certificate([1, 2, 3], point(1, 0.7))
    b = certificate([4, 5, 6], point(6, 0.7))
    forward = Collapse.collapse(source, [a, b])
    backward = Collapse.collapse(source, [b, a])
    assert_equal forward, backward
    assert_equal 2, forward[:collapse_count]
    assert_equal [0, nil, nil], forward[:original_indices]
    assert_empty forward[:edges]
    assert_equal 2, forward[:contraction_history].length
    assert_equal 7, source[:nodes].length
  end

  def test_input_candidate_order_and_cycle_rotation_do_not_change_output
    source = isolated_triangle
    a = triangle_cert
    rotated = a.merge(vertices: [2, 3, 1])
    reverse = a.merge(vertices: [1, 3, 2])
    original = Collapse.collapse(source, [a])
    assert_equal original, Collapse.collapse(source, [rotated])
    assert_equal original, Collapse.collapse(source, [reverse])
    assert_equal 1, Collapse.collapse(source, [a, reverse])[:collapse_count]
  end

  def test_legacy_triangle_key_is_accepted_but_vertices_are_canonical
    source = isolated_triangle
    legacy = triangle_cert.dup
    legacy[:triangle] = legacy.delete(:vertices)
    result = Collapse.collapse(source, [legacy])
    assert_equal 1, result[:collapse_count]
  end

  def test_original_indices_merge_history_and_contraction_history_are_preserved
    source = graph([node(20, 20), node(0, 0), node(2, 0), node(1, 2), node(25, 25)],
                   [[1, 2], [1, 3], [2, 3]], merges: [[9, 4]])
    source = source.merge(contraction_history: [{ from_before: true }.freeze].freeze).freeze
    result = Collapse.collapse(source, [triangle_cert])
    assert_equal 1, result[:collapse_count]
    assert_equal [0, 4, nil], result[:original_indices]
    assert_includes result[:merged_into], [9, 4]
    assert_includes result[:merged_into], [1, nil]
    assert_equal({ from_before: true }, result[:contraction_history].first)
    assert_equal 2, result[:contraction_history].size
  end

  def test_native_certificate_external_los_must_cover_all_boundary_gateways
    source = graph([node(0, 3), node(0, 0), node(2, 0), node(1, 2), node(3, 2)],
                   [[0, 1], [1, 2], [1, 3], [2, 3], [3, 4]])
    missing = triangle_cert(visible: [0])
    blocked = Collapse.collapse(source, [missing])
    assert_equal 0, blocked[:collapse_count]
    accepted = Collapse.collapse(source, [missing], los_validator: ->(*) { true })
    assert_equal 1, accepted[:collapse_count]
    assert_equal [0, 4, nil], accepted[:original_indices]
    assert_equal [[0, 2], [1, 2]], accepted[:edges]
  end

  def test_optional_point_validator_can_veto_native_certified_center
    source = isolated_triangle
    blocked = Collapse.collapse(source, [triangle_cert], point_validator: ->(*) { false })
    assert_equal 0, blocked[:collapse_count]
    assert_equal source[:original_indices], blocked[:original_indices]
    allowed = Collapse.collapse(source, [triangle_cert], point_validator: ->(*) { true })
    assert_equal 1, allowed[:collapse_count]
  end

  def test_malformed_certificate_is_rejected_without_inferred_hole_free_status
    source = isolated_triangle
    [
      { vertices: [1, 2, 3], point: [1, 1, 5] }, # missing radius
      { vertices: [1, 2, 3], point: [Float::NAN, 1, 5], radius: 1 },
      { vertices: [1, 2, 3], point: [1, 1, 5], radius: -1 },
      { vertices: [1, 2, 2], point: [1, 1, 5], radius: 1 },
      { vertices: [1, 2, 3], point: [1, 1, 5], radius: 1, visible_neighbors: ['0'] }
    ].each do |record|
      assert_equal 0, Collapse.collapse(source, [record])[:collapse_count]
    end
  end

  def test_no_input_hash_nodes_edges_or_certificate_arrays_are_mutated
    source = isolated_triangle
    candidate = triangle_cert
    before_nodes = Marshal.dump(source)
    before_certificate = Marshal.dump(candidate)
    Collapse.collapse(source, [candidate])
    assert_equal before_nodes, Marshal.dump(source)
    assert_equal before_certificate, Marshal.dump(candidate)
    assert source[:nodes].frozen?
    assert source[:edges].frozen?
  end

  def test_all_edges_sorted_unique_and_in_range_after_multiple_collapses
    source = graph([node(0, 4), node(0, 0), node(2, 0), node(1, 2),
                    node(5, 0), node(7, 0), node(6, 2), node(10, 2)],
                   [[0, 1], [1, 2], [1, 3], [2, 3], [4, 5], [4, 6], [5, 6], [6, 7]])
    a = triangle_cert(visible: [0])
    b = certificate([4, 5, 6], point(6, 0.7), visible: [7])
    result = Collapse.collapse(source, [a, b])
    assert_equal 2, result[:collapse_count]
    assert_equal 8 - 3 - 3 + 2, result[:nodes].length
    assert_equal result[:nodes].length, result[:original_indices].length
    assert_equal result[:edges].sort.uniq, result[:edges]
    assert result[:edges].all? { |i, j| i.is_a?(Integer) && j.is_a?(Integer) && i < j && j < result[:nodes].length }
    assert_equal 0, result[:original_indices].first
  end

  def test_noop_graph_still_normalizes_edge_order_and_keeps_weights_aligned
    source = graph([node(20, 20), node(0, 0), node(2, 0), node(1, 2)],
                   [[1, 3], [2, 3], [1, 2]])
    source = source.merge(edges: [[2, 3], [1, 3], [1, 2]],
                          edge_weights: [23, 13, 12],
                          edge_metadata: [{ id: 23 }, { id: 13 }, { id: 12 }]).freeze
    before = Marshal.dump(source)
    result = Collapse.collapse(source, [])
    assert_equal [[1, 2], [1, 3], [2, 3]], result[:edges]
    assert_equal [12, 13, 23], result[:edge_weights]
    assert_equal [12, 13, 23], result[:edge_metadata].map { |item| item[:id] }
    assert_equal before, Marshal.dump(source)
  end

  def test_common_primitive_unsupported_added_edge_annotations_fail_closed
    source = isolated_triangle.merge(added_edges: []).freeze
    result = Collapse.collapse(source, [triangle_cert])
    assert_equal 0, result[:collapse_count]
    assert_equal source[:original_indices], result[:original_indices]
  end

  def test_more_than_415_after_nodes_does_not_disable_cycle_reduction
    source = isolated_triangle
    expanded = source[:nodes] + Array.new(420) { |i| node(100 + i, 500) }
    source = graph(expanded, source[:edges])
    result = Collapse.collapse(source, [triangle_cert])
    assert_equal 1, result[:collapse_count]
    assert_equal expanded.size - 3 + 1, result[:nodes].size
  end
end
