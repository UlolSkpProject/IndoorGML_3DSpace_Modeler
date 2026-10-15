# frozen_string_literal: true

# A synthetic COLLAPSED contract; independent of Native loop certificates and
# future implementations of ReferenceGraphLoopCollapser.
module SyntheticCollapsedGraph
  Point = Struct.new(:x, :y, :z)

  module_function

  def point(x, y = 0.0, z = 0.0)
    Point.new(x.to_f, y.to_f, z.to_f).freeze
  end

  def node(x, y = 0.0, z = 0.0, radius: 0.5, **extra)
    { point: point(x, y, z), radius: radius.to_f, **extra }.freeze
  end

  def chain(with_diagnostics: false)
    result = {
      nodes: [node(99, 99), node(0), node(1), node(2), node(3)].freeze,
      edges: [[1, 2], [2, 3], [3, 4]].map(&:freeze).freeze,
      original_indices: [0, nil, 14, 20, 27].freeze,
      merged_into: [[8, nil], [9, 20]].map(&:freeze).freeze,
      contraction_history: [{ stage: :collapsed, members: [6, 7, 8] }.freeze].freeze
    }
    result.merge!(collapse_count: 1, loop_count: 2, eligible_count: 3) if with_diagnostics
    result.freeze
  end

  def graph(nodes, edges, origins: nil, merges: [], history: [], **extra)
    { nodes: nodes.freeze, edges: edges.map { |e| e.dup.freeze }.freeze,
      original_indices: (origins || (0...nodes.length).to_a).freeze,
      merged_into: merges.map { |entry| entry.dup.freeze }.freeze,
      contraction_history: history.dup.freeze, **extra }.freeze
  end
end
