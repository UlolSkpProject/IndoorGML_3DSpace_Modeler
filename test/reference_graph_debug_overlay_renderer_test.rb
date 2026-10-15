# frozen_string_literal: true

require 'minitest/autorun'

# Renderer tests must run outside SketchUp without loading the extension.
unless defined?(Sketchup::Color)
  module Sketchup
    Color = Struct.new(:red, :green, :blue, :alpha)
  end
end
unless defined?(Geom::Point3d)
  module Geom
    Point3d = Struct.new(:x, :y, :z)
  end
end

GL_LINE_STRIP = 3 unless defined?(GL_LINE_STRIP)

require_relative '../indoor3d/ui/overlays/renderers/reference_graph_debug_overlay_renderer'

class ReferenceGraphDebugOverlayRendererTest < Minitest::Test
  Renderer = ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugOverlayRenderer
  Point = Struct.new(:x, :y, :z)
  Direction = Struct.new(:z)
  Camera = Struct.new(:direction)

  class FakeView
    attr_accessor :drawing_color, :line_width, :line_stipple
    attr_reader :camera, :draw_calls, :screen_calls

    def initialize(z)
      @camera = Camera.new(Direction.new(z))
      @draw_calls = []
      @screen_calls = []
    end

    def screen_coords(point)
      @screen_calls << point
      Point.new(point.x * 10.0, point.y * 10.0, 0.0)
    end

    def draw(primitive, points)
      @draw_calls << [:draw, primitive, points]
    end

    def draw2d(primitive, points)
      @draw_calls << [:draw2d, primitive, points]
    end
  end

  def setup
    partition = {
      outer: [Point.new(0, 0, 0), Point.new(4, 0, 0), Point.new(4, 3, 0)],
      holes: [[Point.new(1, 1, 0), Point.new(2, 1, 0), Point.new(1, 2, 0)]]
    }
    model = Struct.new(:debug_floor_partitions).new([partition])
    transform = Object.new
    def transform.overlay_render_points(points)
      points.map { |point| Point.new(point.x + 1, point.y + 2, point.z + 0.5) }
    end
    @renderer = Renderer.new(indoor_model: model, transform_context: transform)
  end

  def test_top_view_draws_closed_outer_and_hole_boundaries_in_screen_space
    view = FakeView.new(-1.0)

    @renderer.draw_partitions(view)

    assert_equal 2, view.draw_calls.length
    assert view.draw_calls.all? { |method, primitive, _| method == :draw2d && primitive == GL_LINE_STRIP }
    outer = view.draw_calls.first.last
    assert_equal outer.first, outer.last
    assert_equal [[10.0, 20.0, 0.0], [50.0, 20.0, 0.0],
                  [50.0, 50.0, 0.0], [10.0, 20.0, 0.0]],
                 outer.map { |point| [point.x, point.y, point.z] }
  end

  def test_oblique_view_draws_floor_boundaries_in_3d
    view = FakeView.new(-0.8)

    @renderer.draw_partitions(view)

    assert_equal [:draw, :draw], view.draw_calls.map(&:first)
    assert_empty view.screen_calls
    assert_equal Renderer::PARTITION_COLOR, view.drawing_color
    assert_equal 1, view.line_width
  end

  def test_extents_cover_all_partition_rings_after_transform
    points = @renderer.extent_points

    assert_equal [[1, 2, 0.5], [5, 5, 0.5]],
                 points.map { |point| [point.x, point.y, point.z] }
  end

  def test_circle_and_graph_edge_rendering_are_removed
    refute_respond_to @renderer, :draw_circles
    refute_respond_to @renderer, :draw_edges
  end
end
