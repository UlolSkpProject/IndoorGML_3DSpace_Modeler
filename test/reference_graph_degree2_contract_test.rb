# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'support/synthetic_collapsed_graph'

class ReferenceGraphDegree2ContractTest < Minitest::Test
  def test_synthetic_fixture_has_nil_origin_and_existing_history
    graph = SyntheticCollapsedGraph.chain
    assert_equal [0, nil, 14, 20, 27], graph[:original_indices]
    assert_equal [[8, nil], [9, 20]], graph[:merged_into]
    assert_equal :collapsed, graph[:contraction_history].first[:stage]
    assert graph.frozen?
  end

  def test_fixture_with_or_without_collapse_diagnostics_has_identical_graph
    plain = SyntheticCollapsedGraph.chain
    diagnostic = SyntheticCollapsedGraph.chain(with_diagnostics: true)
    %i[nodes edges original_indices merged_into contraction_history].each do |field|
      assert_equal plain[field], diagnostic[field], "#{field} must not depend on collapse diagnostics"
    end
    assert_equal [1, 2, 3], diagnostic.values_at(:collapse_count, :loop_count, :eligible_count)
  end

  def test_contract_has_canonical_edges_and_fixed_state_index
    graph = SyntheticCollapsedGraph.chain
    assert_equal 0, graph[:original_indices].first
    assert graph[:edges].all? { |a, b| a < b && a >= 0 && b < graph[:nodes].size }
    assert_equal graph[:edges].sort.uniq, graph[:edges]
    assert_equal graph[:nodes].size, graph[:original_indices].size
  end
end
