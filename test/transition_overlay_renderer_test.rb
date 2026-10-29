# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
end unless defined?(Sketchup)

unless defined?(Sketchup::Color)
  class Sketchup::Color
    attr_reader :values

    def initialize(*values)
      @values = values
    end
  end
end

GL_LINES = :lines unless defined?(GL_LINES)

require_relative '../indoor3d/ui/overlays/renderers/transition_overlay_renderer'

class TransitionOverlayRendererTest < Minitest::Test
  Renderer = ULOL::Indoor3DGmlModeler::IndoorCore::TransitionOverlayRenderer

  class CurveBuilder
    def transition_line_batches(**)
      { normal: [:normal], highlight: [:highlight] }
    end
  end

  class View
    attr_accessor :line_width, :drawing_color
    attr_reader :draws

    def initialize
      @draws = []
    end

    def draw(mode, points)
      @draws << { mode: mode, points: points, line_width: line_width, color: drawing_color }
    end
  end

  def test_highlight_uses_the_default_transition_line_width
    view = View.new

    Renderer.new(curve_builder: CurveBuilder.new).draw(view)

    assert_equal 2, view.draws.length
    assert_equal Renderer::TRANSITION_LINE_WIDTH_PIXELS, view.draws[0][:line_width]
    assert_equal Renderer::TRANSITION_LINE_WIDTH_PIXELS, view.draws[1][:line_width]
    assert_equal [:normal], view.draws[0][:points]
    assert_equal [:highlight], view.draws[1][:points]
    assert_equal 1, view.line_width
  end
end
