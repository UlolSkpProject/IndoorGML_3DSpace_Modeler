# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_contraction'

# Cross-stage contract fixtures; no Ruby Hole/membrane classification.
module CollapsedContractFixture
  Point = Struct.new(:x, :y, :z)

  def point(x, y, z = 5.0)
    Point.new(x.to_f, y.to_f, z.to_f)
  end

  def node(x, y, radius = 1.0, z = 5.0)
    { point: point(x, y, z), radius: radius.to_f }.freeze
  end

  def graph(nodes, edges, origins: nil, merges: [], **fields)
    { nodes: nodes.freeze,
      edges: edges.map { |pair| pair.sort.freeze }.sort.freeze,
      original_indices: (origins || (0...nodes.size).to_a).freeze,
      merged_into: merges.freeze,
      contraction_history: [].freeze,
      **fields }.freeze
  end

  def certificate(ids, center, visible: [], radius: 1.0)
    { vertices: ids.freeze, point: [center.x, center.y, center.z].freeze,
      radius: radius, visible_neighbors: visible.freeze }.freeze
  end
end

class CollapsedContractFixtureTest < Minitest::Test
  include CollapsedContractFixture
  Primitive = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphContraction

  def test_before_original_indices_are_distinct_from_after_local_indices
    after = graph([node(0, 0), node(2, 0), node(3, 1)],
                  [[0, 1], [1, 2]], origins: [0, 7, 12])
    assert_equal 7, after[:original_indices][1]
    assert_equal 1, after[:edges].first[1]
  end

  def test_native_certificate_shape_is_immutable_in_fixture
    cert = certificate([8, 12, 15], point(3, 3), visible: [0, 17])
    assert_equal [8, 12, 15], cert.fetch(:vertices)
    assert_equal [3.0, 3.0, 5.0], cert.fetch(:point)
    assert_equal [0, 17], cert.fetch(:visible_neighbors)
    assert cert.frozen?
  end

  def test_shared_primitive_requires_new_point_validation
    source = graph([node(10, 10), node(1, 1), node(2, 1), node(1, 2)],
                   [[1, 2], [2, 3], [1, 3]])
    outcome = Primitive.contract(source,
                                 members: [1, 2, 3],
                                 representative: :new,
                                 new_node: node(1.3, 1.3),
                                 los_validator: ->(*) { true })
    assert_equal :unverified_representative, outcome[:reason]
    assert_same source, outcome[:graph]
  end
end
