# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session/overlay_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModeScreenOverlay
        OVERLAY_ID = 'ulol.indoor.screen'
      end unless const_defined?(:IndoorModeScreenOverlay, false)

      class DualGraphSpaceOverlay
        OVERLAY_ID = 'ulol.indoor.dualgraph'
      end unless const_defined?(:DualGraphSpaceOverlay, false)
    end
  end
end

class ValidationOverlayControllerIntegrationTest < Minitest::Test
  Controller = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::OverlayController
  ValidationId = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::ValidationOverlayService::OVERLAY_ID

  class FakeOverlay
    attr_accessor :enabled, :geometry
    attr_reader :overlay_id, :geometry_sets

    def initialize(id)
      @overlay_id = id
      @enabled = false
      @geometry_sets = 0
    end

    def valid?
      true
    end

    def set_geometry(value)
      @geometry = value
      @geometry_sets += 1
      true
    end

    def clear
      @geometry = nil
      true
    end

    def enabled?
      @enabled
    end
  end

  class Manager
    include Enumerable

    def initialize
      @items = []
    end

    def each(&block)
      @items.each(&block)
    end

    def add(overlay)
      @items << overlay
      true
    end

    def remove(overlay)
      @items.delete(overlay)
      true
    end

    def size
      @items.size
    end
  end

  class View
    attr_reader :invalidates

    def initialize
      @invalidates = 0
    end

    def invalidate
      @invalidates += 1
    end
  end

  class Model
    attr_reader :overlays, :active_view

    def initialize
      @overlays = Manager.new
      @active_view = View.new
    end

    def valid?
      true
    end
  end

  class Indoor
    attr_reader :model
    attr_accessor :validation

    def initialize(model)
      @model = model
      @validation = true
    end

    def validation_focus_active?
      @validation
    end

    def editing?
      true
    end

    def dual_overlay_visible?
      false
    end
  end

  class Resolver
    attr_reader :clears

    def initialize
      @clears = 0
    end

    def resolve(row)
      row[:geometry]
    end

    def clear_cache
      @clears += 1
      true
    end
  end

  def setup
    @model = Model.new
    @indoor = Indoor.new(@model)
    @screen = FakeOverlay.new('ulol.indoor.screen')
    @space = FakeOverlay.new('ulol.indoor.dualgraph')
    @validation = FakeOverlay.new(ValidationId)
    @resolver = Resolver.new
    @controller = Controller.new(
      indoor_model: @indoor,
      screen_overlay_factory: -> { @screen },
      space_overlay_factory: -> { @space },
      validation_overlay_factory: -> { @validation },
      validation_geometry_resolver_factory: -> { @resolver }
    )
  end

  def row(id)
    {
      id: id,
      geometry: {
        status: :ready,
        face_triangles: [[id, 'p1', 'p2']],
        face_edges: ['p1', 'p2'],
        overlap_triangles: [], overlap_edges: []
      }
    }
  end

  def test_registration_and_repeated_calls_keep_three_independent_overlays
    assert @controller.ensure_registered(@model)
    2.times { assert @controller.ensure_registered(@model) }
    assert_equal 3, @model.overlays.size
    assert_equal [@screen, @space, @validation], @model.overlays.to_a
  end

  def test_validation_geometry_shows_even_when_dualgraph_disabled
    @controller.ensure_registered(@model)
    @controller.update_enabled(editing: true, dual_overlay_visible: false)
    assert @controller.set_validation_geometry(row('A'))
    assert @validation.enabled?
    refute @space.enabled?
    assert @screen.enabled?
  end

  def test_validation_clear_never_changes_dualgraph_enabled
    @controller.ensure_registered(@model)
    @controller.update_enabled(editing: true, dual_overlay_visible: true)
    @controller.set_validation_geometry(row('A'))
    assert @space.enabled?

    @controller.clear_validation_geometry
    refute @validation.enabled?
    assert_nil @validation.geometry
    assert @space.enabled?
    assert @screen.enabled?
  end

  def test_validation_session_cleanup_preserves_other_overlays
    @controller.ensure_registered(@model)
    @controller.update_enabled(editing: true, dual_overlay_visible: true)
    @controller.set_validation_geometry(row('A'))
    assert @controller.end_validation_session

    refute @validation.enabled?
    assert_nil @validation.geometry
    assert @space.enabled?
    assert @screen.enabled?
    assert_equal 0, @resolver.clears
  end

  def test_cellspace_mutation_invalidation_calls_resolver_not_other_overlay
    @controller.ensure_registered(@model)
    @controller.set_validation_geometry(row('A'))
    assert @controller.invalidate_validation_geometry_cache
    assert_equal 1, @resolver.clears
    assert_equal 3, @model.overlays.size
    assert @controller.set_validation_geometry(row('B'))
    assert_equal 2, @validation.geometry_sets
  end

  def test_disabled_validation_session_does_not_force_dualgraph_off
    @controller.ensure_registered(@model)
    @controller.update_enabled(editing: true, dual_overlay_visible: true)
    @controller.set_validation_geometry(row('A'))
    @indoor.validation = false
    @controller.update_enabled(editing: true, dual_overlay_visible: true)
    assert @space.enabled?
    refute @validation.enabled?
  end
end
