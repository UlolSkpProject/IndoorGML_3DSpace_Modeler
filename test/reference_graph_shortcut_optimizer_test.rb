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

  def test_3d_projection_allows_vertical_interior_segment
    a = Point.new(0.0, 0.0, 0.0)
    b = Point.new(0.0, 0.0, 2.0)
    c = Point.new(0.0, 0.0, 4.0)

    assert Optimizer.projected_between?(a, b, c),
           '3D projection must not reject vertical LOS paths'
    refute Optimizer.projected_between?(a, Point.new(0, 0, 5), c),
           'projection beyond a 3D segment must remain invalid'
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

require_relative 'support/synthetic_collapsed_graph'

class ReferenceGraphShortcutOptimizerTest
  Fixture = SyntheticCollapsedGraph

  def test_synthetic_collapsed_graph_handles_nil_origins_and_prior_history
    source = Fixture.chain
    result = Optimizer.optimize(source, los_validator: ->(*) { true })
    assert_equal [0, nil, 27], result[:original_indices]
    assert_equal [2, 3], result[:shortcut_removed_indices]
    assert_equal 2, result[:shortcut_removed_count]
    assert_equal [[1, 2]], result[:edges]
    assert_equal [[1, 2]], result[:shortcut_native_los_edges]
    assert_includes result[:merged_into], [8, nil]
    assert_includes result[:merged_into], [9, 27]
    assert_includes result[:merged_into], [14, 27]
    assert_includes result[:merged_into], [20, 27]
    assert_equal :collapsed, result[:contraction_history].first[:stage]
    assert_equal 3, result[:contraction_history].length
    assert_equal [0, nil, 14, 20, 27], source[:original_indices]
    assert_equal [[1, 2], [2, 3], [3, 4]], source[:edges]
  end

  def test_optional_collapsed_diagnostics_do_not_affect_optimization
    first = Optimizer.optimize(Fixture.chain, los_validator: ->(*) { true })
    last = Optimizer.optimize(Fixture.chain(with_diagnostics: true), los_validator: ->(*) { true })
    %i[nodes edges original_indices merged_into contraction_history
       shortcut_removed_count shortcut_removed_indices shortcut_native_los_edges].each do |key|
      assert_equal first[key], last[key], "optional diagnostic changed #{key}"
    end
  end

  def test_native_exception_is_fail_closed_and_cached
    source = Fixture.graph(
      [Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(3), Fixture.node(2)],
      [[1, 2], [2, 3], [1, 4], [3, 4]]
    )
    calls = 0
    result = Optimizer.optimize(source, los_validator: ->(*) { calls += 1; raise 'Native unavailable' })
    assert_equal 1, calls
    assert_equal 0, result[:shortcut_removed_count]
    assert_equal source[:edges].sort, result[:edges]
    assert_empty result[:shortcut_native_los_edges]
  end

  def test_two_candidates_share_failed_los_cache
    source = Fixture.graph(
      [Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(3), Fixture.node(2)],
      [[1, 2], [2, 3], [1, 4], [3, 4]]
    )
    calls = []
    result = Optimizer.optimize(source, los_validator: lambda { |a, c|
      calls << [a.x, c.x]
      false
    })
    assert_equal [[0.0, 3.0]], calls
    assert_equal 0, result[:shortcut_removed_count]
    assert_equal [0, 1, 2, 3, 4], result[:original_indices]
  end

  def test_redundant_los_after_direct_edge_creation_is_not_repeated
    source = Fixture.graph(
      [Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(3), Fixture.node(2)],
      [[1, 2], [2, 3], [1, 4], [3, 4]]
    )
    calls = 0
    result = Optimizer.optimize(source, los_validator: ->(*) { calls += 1; true })
    assert_equal 1, calls
    assert_equal [2, 4], result[:shortcut_removed_indices]
    assert_equal [0, 1, 3], result[:original_indices]
    assert_equal [[1, 2]], result[:edges]
    assert_equal [[1, 2]], result[:shortcut_native_los_edges]
  end

  def test_state_is_preserved_despite_direct_edge_and_degree_two
    source = Fixture.graph([Fixture.node(1), Fixture.node(0), Fixture.node(2)],
                           [[0, 1], [0, 2], [1, 2]])
    result = Optimizer.optimize(source)
    assert_equal [0, 1, 2], result[:original_indices]
    assert_equal 0, result[:shortcut_removed_count]
  end

  def test_degree_zero_one_and_three_nodes_are_not_removed
    source = Fixture.graph(
      [Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(2),
       Fixture.node(3), Fixture.node(4)], [[1, 2], [1, 3], [1, 4]]
    )
    result = Optimizer.optimize(source, los_validator: ->(*) { true })
    assert_equal 0, result[:shortcut_removed_count]
    assert_equal (0..5).to_a, result[:original_indices]
  end

  def test_projection_at_endpoint_or_beyond_is_not_accepted
    a = Fixture.point(0)
    c = Fixture.point(2)
    refute Optimizer.projected_between?(a, Fixture.point(0), c)
    refute Optimizer.projected_between?(a, Fixture.point(2), c)
    refute Optimizer.projected_between?(a, Fixture.point(-1), c)
    refute Optimizer.projected_between?(a, Fixture.point(4), c)
  end

  def test_z_misalignment_invalidates_xy_only_projection
    a = Fixture.point(0, 0, 0)
    b = Fixture.point(1, 0, -30)
    c = Fixture.point(2, 0, 10)
    # XY would report t = 1/2; true 3D projection is outside AC.
    refute Optimizer.projected_between?(a, b, c)
    source = Fixture.graph([Fixture.node(99), { point: a, radius: 1 },
                            { point: b, radius: 1 }, { point: c, radius: 1 }],
                           [[1, 2], [2, 3]])
    assert_equal 0, Optimizer.optimize(source, los_validator: ->(*) { true })[:shortcut_removed_count]
  end

  def test_removal_can_make_a_degree_three_node_eligible
    source = Fixture.graph(
      [Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(2),
       Fixture.node(-2), Fixture.node(-3)],
      [[1, 2], [2, 3], [1, 3], [1, 4], [4, 5]]
    )
    result = Optimizer.optimize(source, los_validator: ->(*) { true })
    assert_includes result[:shortcut_removed_indices], 2
    assert_includes result[:shortcut_removed_indices], 1
    assert_equal result[:shortcut_removed_count], result[:shortcut_removed_indices].length
    refute_includes result[:original_indices], 1
  end

  def test_representative_prefers_non_nil_origin_over_point_location
    source = Fixture.graph([Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(2)],
                           [[1, 2], [2, 3]], origins: [0, nil, 10, 2])
    calls = []
    result = Optimizer.optimize(source, los_validator: ->(a, b) { calls << [a.x, b.x]; true })
    assert_equal [[2.0, 0.0]], calls
    assert_equal [0, nil, 2], result[:original_indices]
    assert_includes result[:merged_into], [10, 2]
  end

  def test_two_nil_origins_use_coordinates_for_stable_representative
    source = Fixture.graph([Fixture.node(99), Fixture.node(2), Fixture.node(1), Fixture.node(0)],
                           [[1, 2], [2, 3]], origins: [0, nil, 7, nil])
    calls = []
    result = Optimizer.optimize(source, los_validator: ->(a, b) { calls << [a.x, b.x]; true })
    assert_equal [[0.0, 2.0]], calls
    assert_equal [0, nil, nil], result[:original_indices]
    assert_includes result[:merged_into], [7, nil]
  end

  def test_snapshot_without_collapse_diagnostics_or_history_is_complete
    source = { nodes: [Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(2)].freeze,
               edges: [[1, 2], [2, 3]].map(&:freeze).freeze }.freeze
    result = Optimizer.optimize(source, los_validator: ->(*) { true })
    %i[nodes edges original_indices merged_into contraction_history
       shortcut_removed_count shortcut_removed_indices shortcut_native_los_edges].each do |field|
      assert result.key?(field), "missing #{field}"
    end
    assert_equal [0, 1, 3], result[:original_indices]
    assert result.frozen?
    assert result[:edges].frozen?
    assert result[:nodes].all?(&:frozen?)
    assert_equal 4, source[:nodes].length
  end

  def test_metadata_remains_aligned_through_unsorted_input_edges
    source = Fixture.graph([Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(2)],
                           [[2, 3], [1, 3], [1, 2]],
                           edge_weights: [20.0, 30.0, 10.0].freeze,
                           edge_metadata: [{ id: :bc }, { id: :ac }, { id: :ab }].freeze)
    result = Optimizer.optimize(source)
    assert_equal [[1, 2]], result[:edges]
    assert_equal [30.0], result[:edge_weights]
    assert_equal :ac, result[:edge_metadata][0][:id]
    assert_equal [[2, 3], [1, 3], [1, 2]], source[:edges]
  end

  def test_every_edge_is_canonical_and_within_bounds
    result = Optimizer.optimize(Fixture.chain, los_validator: ->(*) { true })
    edges = result[:edges]
    assert_equal edges.sort.uniq, edges
    assert edges.all? { |a, b| a < b && a >= 0 && b < result[:nodes].size }
    assert_equal result[:nodes].size, result[:original_indices].size
  end

  def test_original_input_and_nested_points_remain_unchanged
    source = Fixture.chain
    origin_points = source[:nodes].map { |node| node[:point].to_a }
    output = Optimizer.optimize(source, los_validator: ->(*) { true })
    assert_equal origin_points, source[:nodes].map { |node| node[:point].to_a }
    assert_equal [0, nil, 14, 20, 27], source[:original_indices]
    refute_same source[:nodes][0][:point], output[:nodes][0][:point]
    assert source[:edges].frozen?
    assert source[:merged_into].frozen?
  end

  def test_same_input_and_los_yield_identical_output
    outputs = 2.times.map { Optimizer.optimize(Fixture.chain, los_validator: ->(*) { true }) }
    %i[nodes edges original_indices merged_into contraction_history
       shortcut_removed_count shortcut_removed_indices shortcut_native_los_edges].each do |field|
      assert_equal outputs[0][field], outputs[1][field], field.to_s
    end
  end

  def test_new_shortcuts_do_not_join_separate_components
    source = Fixture.graph([Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(2),
                            Fixture.node(5), Fixture.node(6), Fixture.node(7)],
                           [[1, 2], [2, 3], [4, 5], [5, 6]])
    result = Optimizer.optimize(source, los_validator: ->(*) { true })
    assert_equal component_count(source), component_count(result)
    assert_equal 0, result[:original_indices].first
  end

  def test_rejects_duplicate_source_edges_instead_of_adding_shortcut
    source = Fixture.graph([Fixture.node(99), Fixture.node(0), Fixture.node(1), Fixture.node(2)],
                           [[1, 2], [2, 1], [2, 3]])
    assert_raises(ArgumentError) { Optimizer.optimize(source, los_validator: ->(*) { true }) }
    assert_equal [[1, 2], [2, 1], [2, 3]], source[:edges]
  end

  def test_semantic_gateway_is_not_removed
    source = Fixture.graph([Fixture.node(99), Fixture.node(0), Fixture.node(1, semantic_role: :door),
                            Fixture.node(2)], [[1, 2], [2, 3]])
    assert_equal 0, Optimizer.optimize(source, los_validator: ->(*) { true })[:shortcut_removed_count]
  end

  private

  def component_count(graph)
    adjacency = Array.new(graph[:nodes].length) { [] }
    graph[:edges].each { |a, b| adjacency[a] << b; adjacency[b] << a }
    unseen = (0...adjacency.length).to_a
    count = 0
    until unseen.empty?
      count += 1
      todo = [unseen.shift]
      until todo.empty?
        index = todo.pop
        adjacency[index].each do |neighbor|
          if unseen.delete(neighbor)
            todo << neighbor
          end
        end
      end
    end
    count
  end
end
