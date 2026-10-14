# frozen_string_literal: true

require 'minitest/autorun'

# Renderer tests must run outside SketchUp without loading the extension.
unless defined?(Sketchup::Color)
  module Sketchup
    Color = Struct.new(:red, :green, :blue, :alpha)
  end
end

GL_LINES = 1 unless defined?(GL_LINES)

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
    nodes = [
      { point: Point.new(1.0, 2.0, 0.5), radius: 0.2 },
      { point: Point.new(3.0, 4.0, 0.5), radius: 0.2 }
    ]
    graph = { nodes: nodes, edges: [[0, 1]] }
    model = Struct.new(:debug_reference_graphs).new([graph])
    transform = Object.new
    def transform.overlay_render_points(points)
      points.map { |p| ReferenceGraphDebugOverlayRendererTest::Point.new(p.x + 1, p.y + 2, p.z) }
    end
    @renderer = Renderer.new(indoor_model: model, transform_context: transform)
  end

  def test_top_view_draws_visible_screen_space_lines
    view = FakeView.new(-1.0)

    @renderer.draw_edges(view)

    assert_equal 1, view.draw_calls.size
    method, primitive, points = view.draw_calls.first
    assert_equal :draw2d, method
    assert_equal GL_LINES, primitive
    assert_equal [[20.0, 40.0, 0.0], [40.0, 60.0, 0.0]],
                 points.map { |point| [point.x, point.y, point.z] }
    assert_equal 2, view.screen_calls.size
  end

  def test_near_top_view_uses_screen_space_too
    view = FakeView.new(-0.99)

    @renderer.draw_edges(view)

    assert_equal :draw2d, view.draw_calls.first.first
  end

  def test_oblique_view_preserves_original_3d_edges
    view = FakeView.new(-0.8)

    @renderer.draw_edges(view)

    assert_equal 1, view.draw_calls.size
    method, primitive, points = view.draw_calls.first
    assert_equal :draw, method
    assert_equal GL_LINES, primitive
    assert_equal [[2.0, 4.0, 0.5], [4.0, 6.0, 0.5]],
                 points.map { |point| [point.x, point.y, point.z] }
    assert_empty view.screen_calls
  end
end
