# frozen_string_literal: true

require 'minitest/autorun'

unless defined?(Sketchup)
  module Sketchup; end
end

unless defined?(Sketchup::Color)
  class Sketchup::Color
    def initialize(*); end
  end
end

require_relative '../indoor3d/ui/overlays/renderers/state_overlay_renderer'

class StateOverlayRendererTransformCacheTest < Minitest::Test
  Renderer = ULOL::Indoor3DGmlModeler::IndoorCore::StateOverlayRenderer
  Point = Struct.new(:x, :y, :z)
  Frame = Struct.new(:offset) do
    def to_a
      [offset]
    end
  end
  Group = Struct.new(:name)

  class Cell
    attr_reader :id, :group
    attr_accessor :frame

    def initialize(id, offset)
      @id = id
      @group = Group.new(id)
      @frame = Frame.new(offset)
    end

    def valid_sketchup_group
      group
    end
  end

  State = Struct.new(:name, :duality_cell, :radius) do
    def valid?
      true
    end
  end

  class Selection
    attr_accessor :entities

    def initialize
      @entities = []
    end

    def to_a
      @enumerations = @enumerations.to_i + 1
      entities.dup
    end

    def enumerations
      @enumerations.to_i
    end
  end

  SketchupModel = Struct.new(:selection)

  class IndoorModel
    attr_reader :states, :model, :primal_group

    def initialize(states:, selection:, primal_group:)
      @states = states
      @model = SketchupModel.new(selection)
      @primal_group = primal_group
    end

    def reference_cell_space_transformation(cell_id)
      states.find { |state| state.duality_cell.id == cell_id }.duality_cell.frame
    end

    def refresh_dual_graph_selection_cache
      @snapshot = { entities: model.selection.to_a }
    end

    def dual_graph_selection_snapshot
      @snapshot || { entities: [] }
    end
  end

  class TransformContext
    attr_accessor :primal_offset
    attr_reader :root_local_calls, :batch_calls

    def initialize(primal_offset)
      @primal_offset = primal_offset
      @root_local_calls = []
      @batch_calls = 0
    end

    def overlay_state_visible?(_state)
      true
    end

    def overlay_state_root_local_point(state)
      @root_local_calls << state.name
      Point.new(state.duality_cell.frame.offset, 0, 0)
    end

    def overlay_render_point(point)
      Point.new(point.x + primal_offset, point.y, point.z)
    end

    def overlay_render_points(points)
      @batch_calls += 1
      points.map { |point| overlay_render_point(point) }
    end

    def overlay_render_context_cache_key
      [primal_offset]
    end
  end

  class View
    attr_reader :point_batches, :point_styles

    def initialize
      @point_batches = []
      @point_styles = []
    end

    def draw_points(points, size, style, color)
      @point_batches << points.map(&:dup)
      @point_styles << [size, style, color]
    end
  end

  def setup
    @selection = Selection.new
    @primal_group = Group.new('IndoorGML_PrimalSpaceFeatures')
    @cell_a = Cell.new('A', 10)
    @cell_b = Cell.new('B', 20)
    @state_a = State.new('state-a', @cell_a, 1)
    @state_b = State.new('state-b', @cell_b, 1)
    @context = TransformContext.new(100)
    @indoor_model = IndoorModel.new(
      states: [@state_a, @state_b],
      selection: @selection,
      primal_group: @primal_group
    )
    @indoor_model.refresh_dual_graph_selection_cache
    @renderer = Renderer.new(indoor_model: @indoor_model, transform_context: @context)
    @view = View.new
  end

  def test_unselected_cell_keeps_cached_state_point
    draw
    @cell_a.frame = Frame.new(15)

    draw

    assert_equal [110, 120], last_x_coordinates
    assert_equal %w[state-a state-b], @context.root_local_calls
    assert_equal 1, @context.batch_calls
  end

  def test_selected_cell_refreshes_only_its_state_when_transform_changes
    draw
    select(@cell_a.group)
    @cell_a.frame = Frame.new(15)

    draw

    assert_equal [115, 120], last_x_coordinates
    assert_equal %w[state-a state-b state-a], @context.root_local_calls
    assert_equal 1, @context.batch_calls

    draw
    assert_equal %w[state-a state-b state-a], @context.root_local_calls
  end

  def test_multiple_selected_cells_refresh_independently
    draw
    select(@cell_a.group, @cell_b.group)
    @cell_a.frame = Frame.new(16)
    @cell_b.frame = Frame.new(27)

    draw

    assert_equal [116, 127], last_x_coordinates
    assert_equal %w[state-a state-b state-a state-b], @context.root_local_calls
  end

  def test_selected_cell_includes_primal_render_context_in_its_fingerprint
    draw
    select(@cell_a.group)
    @context.primal_offset = 200

    draw

    assert_equal [210, 220], last_x_coordinates
    assert_equal %w[state-a state-b state-a state-b], @context.root_local_calls
    assert_equal 2, @context.batch_calls
  end

  def test_unselected_primal_transform_change_rebuilds_all_state_points
    draw
    @context.primal_offset = 200

    draw

    assert_equal [210, 220], last_x_coordinates
    assert_equal %w[state-a state-b state-a state-b], @context.root_local_calls
    assert_equal 2, @context.batch_calls
  end

  def test_selected_primal_rebuilds_all_state_points_when_transform_changes
    draw
    select(@primal_group)
    @context.primal_offset = 200

    draw

    assert_equal [210, 220], last_x_coordinates
    assert_equal %w[state-a state-b state-a state-b], @context.root_local_calls
    assert_equal 2, @context.batch_calls

    draw
    assert_equal 2, @context.batch_calls
  end

  def test_selected_state_overlay_uses_existing_cached_points_and_larger_magenta_style
    draw
    @renderer.draw_highlight(@view, selected_cell_ids: { 'B' => true })
    assert_equal [120], last_x_coordinates
    assert_equal 2, @view.point_batches.length
    assert_equal [
      Renderer::STATE_BASE_POINT_SIZE_PIXELS.to_i,
      Renderer::STATE_POINT_STYLE,
      Renderer::DUAL_STATE_COLOR
    ], @view.point_styles[0]
    assert_equal [
      18,
      Renderer::STATE_POINT_STYLE,
      Renderer::SELECTED_STATE_COLOR
    ], @view.point_styles[1]
    assert_equal 1, @context.batch_calls

    @renderer.draw_highlight(@view, selected_cell_ids: { 'A' => true, 'B' => true })
    assert_equal [110, 120], last_x_coordinates
    assert_equal 1, @context.batch_calls
    @renderer.draw_highlight(@view, selected_cell_ids: {})
    assert_equal 3, @view.point_batches.length
  end

  def test_selected_state_highlight_uses_refreshed_transform_without_rebuilding_cache
    draw
    select(@cell_a.group)
    @cell_a.frame = Frame.new(18)

    @renderer.draw_highlight(@view, selected_cell_ids: { 'A' => true })

    assert_equal [118], last_x_coordinates
    assert_equal 1, @context.batch_calls
    assert_equal %w[state-a state-b state-a], @context.root_local_calls
  end

  def test_camera_redraw_uses_selected_entity_cache_without_selection_enumeration
    select(@cell_a.group)
    draw
    count = @selection.enumerations
    4.times { draw }
    assert_equal count, @selection.enumerations

    @cell_a.frame = Frame.new(19)
    draw
    assert_equal [119, 120], last_x_coordinates
    assert_equal count, @selection.enumerations
  end

  private

  def select(*entities)
    @selection.entities = entities
    @indoor_model.refresh_dual_graph_selection_cache
  end

  def draw
    @renderer.draw(@view)
  end

  def last_x_coordinates
    @view.point_batches.last.map(&:x)
  end
end
