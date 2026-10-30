# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session/validation_overlay_service'

class ValidationOverlayServiceTest < Minitest::Test
  Service = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::ValidationOverlayService
  ID = Service::OVERLAY_ID

  class Overlay
    attr_reader :overlay_id, :geometry, :sets, :clears, :enable_writes
    attr_accessor :enabled, :valid

    def initialize(id = ID)
      @overlay_id = id
      @geometry = nil
      @enabled = false
      @valid = true
      @sets = 0
      @clears = 0
      @enable_writes = 0
    end

    def valid?
      @valid
    end

    def set_geometry(geometry)
      @geometry = geometry
      @sets += 1
      true
    end

    def clear
      @clears += 1
      @geometry = nil
      true
    end

    def enabled=(value)
      @enable_writes += 1
      @enabled = value
    end

    def enabled?
      @enabled
    end
  end

  class IncompatibleOverlay
    attr_reader :overlay_id

    def initialize
      @overlay_id = ID
    end

    def valid?
      true
    end
  end

  class OverlayManager
    include Enumerable
    attr_reader :added, :removed

    def initialize(entries = [])
      @entries = entries.dup
      @added = []
      @removed = []
    end

    def each(&block)
      @entries.each(&block)
    end

    def add(overlay)
      @added << overlay
      @entries << overlay
      true
    end

    def remove(overlay)
      @removed << overlay
      @entries.delete(overlay)
      true
    end

    def size
      @entries.size
    end
  end

  class View
    attr_reader :invalidations

    def initialize
      @invalidations = 0
    end

    def invalidate
      @invalidations += 1
    end
  end

  class Model
    attr_accessor :overlays, :valid
    attr_reader :active_view

    def initialize(overlays: OverlayManager.new)
      @overlays = overlays
      @active_view = View.new
      @valid = true
    end

    def valid?
      @valid
    end
  end

  Indoor = Struct.new(:model)

  class Resolver
    attr_reader :resolves, :clears, :cleared_cell_ids

    def initialize
      @resolves = 0
      @clears = 0
      @cleared_cell_ids = []
    end

    def resolve(row)
      @resolves += 1
      raise 'Resolver broken' if row[:raise]

      row[:geometry]
    end

    def clear_cache(cell_ids: nil)
      @clears += 1
      @cleared_cell_ids << cell_ids
      true
    end
  end

  def setup
    @model = Model.new
    @indoor = Indoor.new(@model)
    @created = []
    @resolvers = []
    @service = Service.new(
      indoor_model: @indoor,
      overlay_factory: -> { item = Overlay.new; @created << item; item },
      resolver_factory: -> { item = Resolver.new; @resolvers << item; item }
    )
  end

  def row(id, faces: true, overlap: false)
    {
      id: id,
      geometry: {
        status: :ready,
        face_triangles: faces ? [[1, 2, 3]] : [],
        face_edges: faces ? [1, 2] : [],
        overlap_triangles: overlap ? [[4, 5, 6]] : [],
        overlap_edges: overlap ? [4, 5] : []
      }
    }
  end

  def ready
    assert @service.ensure_registered(@model), @service.last_error
    assert @service.set_enabled(true)
  end

  def test_first_registration_and_repeated_registration_do_not_duplicate
    assert @service.ensure_registered(@model)
    assert_equal 1, @model.overlays.size
    assert_equal 1, @created.size

    3.times { assert @service.ensure_registered(@model) }
    assert_equal 1, @model.overlays.size
    assert_equal 1, @created.size
  end

  def test_reuses_existing_registered_overlay_without_creating_another
    existing = Overlay.new
    existing.set_geometry(row('old')[:geometry])
    existing.enabled = true
    @model.overlays.add(existing)

    assert @service.ensure_registered(@model)
    assert_same existing, @service.overlay
    assert_empty @created
    assert_equal 1, @model.overlays.size
    assert_nil existing.geometry
    refute existing.enabled?
  end

  def test_duplicate_validation_overlay_id_is_reconciled
    first = Overlay.new
    second = Overlay.new
    @model.overlays.add(first)
    @model.overlays.add(second)
    assert @service.ensure_registered(@model)
    assert_equal 1, @model.overlays.size
    assert_same first, @service.overlay
    assert_includes @model.overlays.removed, second
  end

  def test_incompatible_or_invalid_existing_overlay_is_replaced
    incompatible = IncompatibleOverlay.new
    invalid = Overlay.new
    invalid.valid = false
    @model.overlays.add(incompatible)
    @model.overlays.add(invalid)

    assert @service.ensure_registered(@model)
    assert_equal 1, @model.overlays.size
    assert_equal 1, @created.size
    assert_equal 2, @model.overlays.removed.size
  end

  def test_row_a_to_b_replaces_geometry_without_creating_overlay
    ready
    a = row('A')
    b = row('B', faces: false, overlap: true)
    assert_equal a[:geometry], @service.show(@model, a)
    overlay = @service.overlay
    assert overlay.enabled?
    assert_equal b[:geometry], @service.show(@model, b)
    assert_same overlay, @service.overlay
    assert_equal b[:geometry], overlay.geometry
    assert_equal 1, @model.overlays.size
    assert_equal 2, @resolvers.last.resolves
  end

  def test_repeated_same_row_is_idempotent_with_no_extra_invalidate
    ready
    a = row('A')
    @service.show(@model, a)
    initial = @model.active_view.invalidations
    initial_sets = @service.overlay.sets
    initial_resolves = @resolvers.last.resolves

    3.times { assert @service.show(@model, a) }
    assert_equal initial, @model.active_view.invalidations
    assert_equal initial_sets, @service.overlay.sets
    assert_equal initial_resolves, @resolvers.last.resolves
  end

  def test_deselection_clears_and_disables_without_cache_eviction
    ready
    @service.show(@model, row('A'))
    assert @service.clear
    assert_nil @service.overlay.geometry
    refute @service.overlay.enabled?
    assert_equal 0, @resolvers.last.clears
    assert_equal 1, @model.overlays.size
  end

  def test_repeated_clear_does_not_rewrite_or_invalidate
    ready
    @service.show(@model, row('A'))
    @service.clear
    writes = @service.overlay.enable_writes
    count = @model.active_view.invalidations
    3.times { assert @service.clear }
    assert_equal writes, @service.overlay.enable_writes
    assert_equal count, @model.active_view.invalidations
  end

  def test_session_end_clears_disables_and_drops_only_local_cache
    ready
    @service.show(@model, row('A', faces: true, overlap: true))
    resolver = @resolvers.last
    assert @service.end_session
    refute @service.overlay.enabled?
    assert_nil @service.overlay.geometry
    assert_equal 0, resolver.clears
    @service.show(@model, row('B'))
    assert_equal 2, @resolvers.size
  end

  def test_model_switch_clears_old_model_and_registers_new_instance
    ready
    @service.show(@model, row('A'))
    old_overlay = @service.overlay
    new_model = Model.new
    @indoor.model = new_model

    assert @service.ensure_registered(new_model)
    refute old_overlay.enabled?
    assert_nil old_overlay.geometry
    assert_equal 1, @model.overlays.size
    assert_equal 1, new_model.overlays.size
    refute_same old_overlay, @service.overlay
  end

  def test_model_switch_to_invalid_target_still_disables_previous_overlay
    ready
    @service.show(@model, row('A'))
    previous = @service.overlay
    replacement = Model.new
    replacement.valid = false
    @indoor.model = replacement

    refute @service.ensure_registered(replacement)
    assert_nil previous.geometry
    refute previous.enabled?
    assert_equal 1, @model.overlays.size
  end

  def test_overlay_api_unavailable_reports_failure
    @model.overlays = nil
    refute @service.ensure_registered(@model)
    assert_includes @service.last_error, 'Overlay API'
    assert_empty @created
  end

  def test_invalid_model_reports_failure_without_reusing_previous_scene
    @model.valid = false
    refute @service.ensure_registered(@model)
    assert_empty @created
  end

  def test_face_only_geometry_and_overlap_only_geometry
    ready
    face = row('F', faces: true, overlap: false)
    overlap = row('O', faces: false, overlap: true)
    assert_equal face[:geometry], @service.show(@model, face)
    assert_equal face[:geometry], @service.overlay.geometry
    assert_equal overlap[:geometry], @service.show(@model, overlap)
    assert_equal overlap[:geometry], @service.overlay.geometry
  end

  def test_face_and_overlap_geometry_are_preserved_together
    ready
    combined = row('BOTH', faces: true, overlap: true)
    assert_equal combined[:geometry], @service.show(@model, combined)
    assert_equal [[1, 2, 3]], @service.overlay.geometry[:face_triangles]
    assert_equal [[4, 5, 6]], @service.overlay.geometry[:overlap_triangles]
  end

  def test_empty_geometry_does_not_leave_stale_row
    ready
    @service.show(@model, row('A'))
    empty = row('NO', faces: false, overlap: false)
    assert_nil @service.show(@model, empty)
    assert_nil @service.overlay.geometry
    refute @service.overlay.enabled?
  end

  def test_resolver_error_clears_old_geometry_and_reports_failure
    ready
    @service.show(@model, row('A'))
    broken = row('B').merge(raise: true)
    assert_nil @service.show(@model, broken)
    assert_nil @service.overlay.geometry
    refute @service.overlay.enabled?
    assert_includes @service.last_error, 'Resolver broken'
  end

  def test_missing_overlay_api_after_row_a_clears_stale_geometry
    ready
    assert @service.show(@model, row('A'))
    overlay = @service.overlay
    @model.overlays = nil

    assert_nil @service.show(@model, row('B'))
    assert_nil overlay.geometry
    refute overlay.enabled?
    assert_includes @service.last_error, 'Overlay API'
  end

  def test_missing_resolver_after_previous_row_does_not_leave_geometry
    ready
    @service.show(@model, row('A'))
    overlay = @service.overlay
    @service.instance_variable_set(:@resolver, nil)
    @service.instance_variable_set(:@resolver_factory, -> { nil })

    assert_nil @service.show(@model, row('B'))
    assert_nil overlay.geometry
    refute overlay.enabled?
    assert_includes @service.last_error, 'resolver'
  end

  def test_failed_geometry_status_clears_row_and_reports_original_error
    ready
    @service.show(@model, row('A'))
    failure = row('B')
    failure[:geometry] = { status: :failed, reason: 'overlap intersection unavailable',
                           face_triangles: [], face_edges: [],
                           overlap_triangles: [], overlap_edges: [] }
    assert_nil @service.show(@model, failure)
    assert_nil @service.overlay.geometry
    assert_includes @service.last_error, 'overlap intersection unavailable'
  end

  def test_overlay_clear_failure_is_reported_and_can_be_retried
    ready
    @service.show(@model, row('A'))
    overlay = @service.overlay
    original_clear = overlay.method(:clear)
    overlay.define_singleton_method(:clear) { false }

    refute @service.clear
    assert_includes @service.last_error, 'Clear'
    overlay.define_singleton_method(:clear, original_clear)
    assert @service.clear
    assert_nil overlay.geometry
  end

  def test_overlay_enable_failure_does_not_leave_previous_row_geometry
    ready
    overlay = @service.overlay
    overlay.define_singleton_method(:enabled=) do |value|
      @enable_writes += 1
      @enabled = false
    end
    assert_nil @service.show(@model, row('A'))
    refute overlay.enabled?
    assert_nil overlay.geometry
  end

  def test_row_transition_does_not_call_cache_clear
    ready
    @service.show(@model, row('A'))
    @service.clear
    @service.show(@model, row('B'))
    assert_equal 0, @resolvers.last.clears
  end

  def test_mutation_invalidation_clears_resolver_cache_only_on_explicit_call
    ready
    same_row = row('A')
    @service.show(@model, same_row)
    resolver = @resolvers.last
    assert @service.invalidate_geometry_cache
    assert_equal 1, resolver.clears
    @service.show(@model, same_row)
    assert_equal 2, resolver.resolves
  end

  def test_mutation_invalidation_forwards_changed_cell_ids
    ready
    @service.show(@model, row('A'))
    resolver = @resolvers.last

    assert @service.invalidate_geometry_cache(cell_ids: %w[cell_A B])

    assert_equal [%w[cell_A B]], resolver.cleared_cell_ids
  end

  def test_enabled_policy_preserves_row_geometry_when_temporarily_disabled
    ready
    @service.show(@model, row('A'))
    assert @service.set_enabled(false)
    refute @service.overlay.enabled?
    refute_nil @service.overlay.geometry
    assert @service.set_enabled(true)
    assert @service.overlay.enabled?
  end

  def test_unrelated_overlay_enabled_status_is_never_changed
    dualgraph = Overlay.new('ulol.dualgraph')
    dualgraph.enabled = true
    @model.overlays.add(dualgraph)
    ready
    @service.show(@model, row('A'))
    @service.end_session
    assert dualgraph.enabled?
    assert_equal 1, dualgraph.enable_writes
    assert_equal 2, @model.overlays.size
  end
end
