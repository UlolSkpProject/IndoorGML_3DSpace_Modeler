# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/validity/validation_error_geometry_resolver'
require_relative '../indoor3d/infrastructure/scene/editor_session/validation_overlay_service'

class ValidationOverlayEvidenceCacheTest < Minitest::Test
  Resolver = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::ValidationErrorGeometryResolver
  Service = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::ValidationOverlayService
  Indoor = Struct.new(:model)

  def setup
    @model = Object.new
    @other_model = Object.new
    @geometry = { status: :ready, triangles: [['A', 'B', 'C']], edges: [] }
    Resolver.store_overlap_geometry(model: @model, cell_ids: %w[A B], geometry: @geometry)
    Resolver.store_overlap_geometry(model: @other_model, cell_ids: %w[C D], geometry: @geometry)
    @service = Service.new(
      indoor_model: Indoor.new(@model),
      overlay_factory: -> { nil },
      resolver_factory: -> { nil }
    )
  end

  def teardown
    Resolver.clear_overlap_geometry(model: @model)
    Resolver.clear_overlap_geometry(model: @other_model)
  end

  def test_row_clear_does_not_discard_overlap_evidence
    assert @service.clear
    assert_same @geometry, Resolver.fetch_overlap_geometry(model: @model, cell_ids: %w[B A])
  end

  def test_session_end_discards_local_resolver_only_not_shared_overlap_evidence
    assert @service.end_session
    assert_same @geometry, Resolver.fetch_overlap_geometry(model: @model, cell_ids: %w[A B])
  end

  def test_explicit_geometry_mutation_invalidates_only_own_model_evidence
    assert @service.invalidate_geometry_cache
    assert_nil Resolver.fetch_overlap_geometry(model: @model, cell_ids: %w[A B])
    assert_same @geometry, Resolver.fetch_overlap_geometry(model: @other_model, cell_ids: %w[C D])
  end
end
