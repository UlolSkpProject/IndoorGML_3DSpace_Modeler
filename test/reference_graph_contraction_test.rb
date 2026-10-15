# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_contraction'

class ReferenceGraphContractionTest < Minitest::Test
  Contract = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphContraction
  Point = Struct.new(:x, :y, :z)

  def node(x, y = 0, z = 1, radius = 1)
    { point: Point.new(x.to_f, y.to_f, z.to_f), radius: radius.to_f }.freeze
  end

  def graph(nodes, edges, **extra)
    { nodes: nodes.freeze, edges: edges.map(&:freeze).freeze, **extra }.freeze
  end

  def corridor
    graph([node(0), node(1), node(2), node(3), node(4)],
          [[0, 1], [1, 2], [2, 3], [2, 4]])
  end

  def test_relinks_every_external_neighbor_after_native_los
    calls = []
    source = corridor
    result = Contract.contract(source, members: [2, 1], representative: 1,
                               los_validator: ->(a, b) { calls << [a.x, b.x]; true })
    assert result[:accepted]
    assert_equal :ok, result[:reason]
    assert_equal [[1.0, 3.0], [1.0, 4.0]], calls
    assert_equal 2, result[:los_checks]
    assert_equal [0, 3, 4], result[:boundary_indices]
    assert_equal [2], result[:removed_indices]
    assert_equal [0, 1, 3, 4], result[:graph][:original_indices]
    assert_equal [[0, 1], [1, 2], [1, 3]], result[:graph][:edges]
    assert_equal [[1, 2], [1, 3]], result[:new_edges]
    assert_equal [[2, 1]], result[:graph][:merged_into]
    assert_equal [[0, 1], [1, 2], [2, 3], [2, 4]], source[:edges]
    assert_equal 5, source[:nodes].length
  end

  def test_one_blocked_external_neighbor_cancels_all_contraction
    source = corridor
    result = Contract.contract(source, members: [1, 2], representative: 1,
                               los_validator: ->(_a, b) { b.x != 4.0 })
    refute result[:accepted]
    assert_equal :native_los_blocked, result[:reason]
    assert_equal 2, result[:los_checks]
    assert_same source, result[:graph]
  end

  def test_unavailable_los_never_creates_shortcut
    result = Contract.contract(corridor, members: [1, 2], representative: 1)
    refute result[:accepted]
    assert_equal :native_los_unavailable, result[:reason]
    assert_empty result[:new_edges]
  end

  def test_state_is_never_removed_or_moved
    source = graph([node(0), node(1), node(2), node(3)],
                   [[0, 1], [0, 2], [1, 2], [1, 3]])
    refute Contract.contract(source, members: [0, 1], representative: 1,
                            los_validator: ->(*) { true })[:accepted]
    ok = Contract.contract(source, members: [0, 1], representative: 0,
                           los_validator: ->(*) { true })
    assert ok[:accepted]
    assert_equal [0, 2, 3], ok[:graph][:original_indices]
    assert_equal [[0, 1], [0, 2]], ok[:graph][:edges]
    assert_equal source[:nodes][0][:point], ok[:graph][:nodes][0][:point]
    assert_equal 0, ok[:graph][:contraction_history][0][:representative_index]
  end

  def test_protected_node_cannot_be_absorbed
    result = Contract.contract(corridor, members: [1, 2], representative: 1,
                               protected_indices: [2], los_validator: ->(*) { true })
    assert_equal :protected_member, result[:reason]
    refute result[:accepted]
  end

  def test_disconnected_members_cannot_be_joined
    source = graph([node(0), node(1), node(2), node(3)], [[0, 1], [2, 3]])
    result = Contract.contract(source, members: [1, 2], representative: 1,
                               los_validator: ->(*) { true })
    assert_equal :disconnected_members, result[:reason]
  end

  def test_new_representative_requires_valid_solid_point_and_every_los
    source = graph([node(0), node(1), node(2), node(3)],
                   [[0, 1], [1, 2], [2, 3]])
    candidate = node(1.5)
    kwargs = { members: [1, 2], representative: :new, new_node: candidate,
               los_validator: ->(*) { true } }
    assert_equal :unverified_representative, Contract.contract(source, **kwargs)[:reason]
    rejected = Contract.contract(source, **kwargs,
                                 point_validator: ->(_point, _radius) { false })
    assert_equal :unverified_representative, rejected[:reason]
    accepted = Contract.contract(source, **kwargs,
                                 point_validator: ->(_point, _radius) { true })
    assert accepted[:accepted]
    assert_equal 4, accepted[:los_checks]
    assert_equal [0, 3, nil], accepted[:graph][:original_indices]
    assert_equal [[0, 2], [1, 2]], accepted[:graph][:edges]
    assert_equal [[1, nil], [2, nil]], accepted[:graph][:merged_into]
    assert_equal 2, accepted[:graph][:contraction_history][0][:representative_index]
  end

  def test_edge_weights_and_metadata_survive_reindex_and_relink
    source = graph([node(0), node(1), node(2), node(3)],
                   [[2, 3], [1, 2], [0, 1]],
                   edge_weights: [12.0, 11.0, 10.0].freeze,
                   edge_metadata: [{ id: :third }, { id: :internal }, { id: :first }].freeze)
    result = Contract.contract(source, members: [1, 2], representative: 1,
                               los_validator: ->(*) { true })
    assert result[:accepted]
    output = result[:graph]
    assert_equal [[0, 1], [1, 2]], output[:edges]
    assert_equal [10.0, 2.0], output[:edge_weights]
    assert_equal :first, output[:edge_metadata][0][:id]
    assert_equal :native_los, output[:edge_metadata][1][:source]
    assert_equal [12.0, 11.0, 10.0], source[:edge_weights]
  end

  def test_previous_merges_remain_traceable_when_representative_absorbed
    source = corridor.merge(merged_into: [[7, 2], [8, 7]].freeze).freeze
    result = Contract.contract(source, members: [1, 2], representative: 1,
                               los_validator: ->(*) { true })
    assert result[:accepted]
    assert_includes result[:graph][:merged_into], [7, 1]
    assert_includes result[:graph][:merged_into], [8, 1]
    assert_includes result[:graph][:merged_into], [2, 1]
  end

  def test_original_and_accepted_snapshots_are_independent_and_frozen
    source = corridor
    result = Contract.contract(source, members: [1, 2], representative: 1,
                               los_validator: ->(*) { true })
    assert result[:graph].frozen?
    assert result[:graph][:nodes].frozen?
    assert result[:graph][:edges].frozen?
    assert result[:graph][:nodes][1].frozen?
    assert result[:graph][:nodes][1][:point].frozen?
    refute_same source[:nodes][1][:point], result[:graph][:nodes][1][:point]
    assert_equal 5, source[:nodes].length
  end

  def test_reversed_members_and_edges_produce_identical_result
    a = corridor
    b = graph(a[:nodes], a[:edges].reverse.map(&:reverse))
    first = Contract.contract(a, members: [1, 2], representative: 1,
                             los_validator: ->(*) { true })
    second = Contract.contract(b, members: [2, 1], representative: 1,
                              los_validator: ->(*) { true })
    assert_equal first[:graph][:edges], second[:graph][:edges]
    assert_equal first[:graph][:original_indices], second[:graph][:original_indices]
    assert_equal first[:new_edges], second[:new_edges]
    assert_equal first[:graph][:contraction_history], second[:graph][:contraction_history]
  end

  def test_fail_closed_on_duplicate_edges_and_invalid_member_types
    duplicated = graph([node(0), node(1)], [[0, 1], [1, 0]])
    assert_equal :duplicate_edge,
                 Contract.contract(duplicated, members: [0, 1], representative: 0)[:reason]
    assert_equal :invalid_members,
                 Contract.contract(corridor, members: [1, '2'], representative: 1)[:reason]
  end

  def test_rejects_bad_geometry_and_blocked_edge_annotations
    invalid = graph([node(0), node(1, 0, 1, Float::NAN)], [[0, 1]])
    assert_equal :invalid_nodes, Contract.contract(invalid, members: [0, 1], representative: 0)[:reason]
    diagnostic = corridor.merge(added_edges: [{ classification: :blocked }]).freeze
    assert_equal :unsupported_edge_annotations,
                 Contract.contract(diagnostic, members: [1, 2], representative: 1)[:reason]
  end

  def test_existing_los_edges_need_no_new_validator_or_duplicate_edges
    source = graph([node(0), node(1), node(2), node(3)],
                   [[0, 1], [1, 2], [1, 3], [2, 3]])
    result = Contract.contract(source, members: [1, 2], representative: 1)
    assert result[:accepted]
    assert_equal 0, result[:los_checks]
    assert_equal [[0, 1], [1, 2]], result[:graph][:edges]
    assert_empty result[:new_edges]
  end
end
