# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/validity/validation_error_geometry_resolver'

class ValidationErrorGeometryResolverTest < Minitest::Test
  Resolver = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::ValidationErrorGeometryResolver

  def test_201_uses_vertices_and_edges_without_face_fill
    resolver = Resolver.new(indoor_model: nil)
    geometry = resolver.send(:empty_geometry)
    snapshot = {
      triangles: [[:triangle]],
      vertices: [:vertex1, :vertex2],
      edges: [:edge1, :edge2]
    }

    resolver.send(
      :append_face_snapshot,
      geometry,
      snapshot,
      vertex_edge_only: resolver.send(:vertex_edge_only_error?, code: 201)
    )

    assert_empty geometry[:face_triangles]
    assert_equal [:vertex1, :vertex2], geometry[:face_vertices]
    assert_equal [:edge1, :edge2], geometry[:face_edges]
  end

  def test_other_face_errors_keep_filled_face_overlay
    resolver = Resolver.new(indoor_model: nil)
    geometry = resolver.send(:empty_geometry)
    snapshot = {
      triangles: [[:triangle]],
      vertices: [:vertex1],
      edges: [:edge1]
    }

    resolver.send(
      :append_face_snapshot,
      geometry,
      snapshot,
      vertex_edge_only: resolver.send(:vertex_edge_only_error?, code: 203)
    )

    assert_equal [[:triangle]], geometry[:face_triangles]
    assert_empty geometry[:face_vertices]
    assert_equal [:edge1], geometry[:face_edges]
  end

  def test_local_pair_cache_invalidation_keeps_unrelated_pairs
    model = Object.new
    resolver = Resolver.new(indoor_model: nil, model: model)
    pair_cache = resolver.instance_variable_get(:@pair_cache)
    pair_cache[%w[A B]] = { status: :ready }
    pair_cache[%w[A C]] = { status: :ready }
    pair_cache[%w[C D]] = { status: :ready }

    resolver.clear_cache(cell_ids: ['solid_A'])

    refute pair_cache.key?(%w[A B])
    refute pair_cache.key?(%w[A C])
    assert pair_cache.key?(%w[C D])
  ensure
    Resolver.clear_overlap_geometry(model: model) if model
  end
end
