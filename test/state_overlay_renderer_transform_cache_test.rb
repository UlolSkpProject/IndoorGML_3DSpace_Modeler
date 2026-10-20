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
      entities.dup
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
    attr_reader :point_batches

    def initialize
      @point_batches = []
    end

    def draw_points(points, *)
      @point_batches << points.map(&:dup)
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
    @selection.entities = [@cell_a.group]
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
    @selection.entities = [@cell_a.group, @cell_b.group]
    @cell_a.frame = Frame.new(16)
    @cell_b.frame = Frame.new(27)

    draw

    assert_equal [116, 127], last_x_coordinates
    assert_equal %w[state-a state-b state-a state-b], @context.root_local_calls
  end

  def test_selected_cell_includes_primal_render_context_in_its_fingerprint
    draw
    @selection.entities = [@cell_a.group]
    @context.primal_offset = 200

    draw

    assert_equal [210, 120], last_x_coordinates
    assert_equal %w[state-a state-b state-a], @context.root_local_calls
  end

  def test_selected_primal_rebuilds_all_state_points_when_transform_changes
    draw
    @selection.entities = [@primal_group]
    @context.primal_offset = 200

    draw

    assert_equal [210, 220], last_x_coordinates
    assert_equal %w[state-a state-b state-a state-b], @context.root_local_calls
    assert_equal 2, @context.batch_calls

    draw
    assert_equal 2, @context.batch_calls
  end

  private

  def draw
    @renderer.draw(@view)
  end

  def last_x_coordinates
    @view.point_batches.last.map(&:x)
  end
end
