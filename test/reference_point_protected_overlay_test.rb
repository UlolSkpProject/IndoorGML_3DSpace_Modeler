# frozen_string_literal: true

require 'minitest/autorun'

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

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLifecycleContext; end
      class CellSpaceLifecycleLocalGridContext; end
      class IndoorModel; end
    end
  end
end

require_relative '../indoor3d/application/adjacency_service/reference_graph_debug_mode'
require_relative '../indoor3d/application/indoor_model/cell_space_batch_lifecycle'
require_relative '../indoor3d/ui/overlays/renderers/reference_point_debug_overlay_renderer'

class ReferencePointProtectedOverlayTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Renderer = Core::ReferencePointDebugOverlayRenderer
  Point = Geom::Point3d

  class View
    attr_reader :points
    def initialize = @points = []
    def draw_points(points, size, style, color)
      @points << { points: points, size: size, style: style, color: color }
    end
  end

  def p(x, y)
    Point.new(x, y, 5)
  end

  def build_model
    model = Core::IndoorModel.allocate
    model.extend(Core::IndoorModel::CellSpaceBatchLifecycle)
    model.instance_variable_set(
      :@debug_reference_graph_overlay_by_cell_id,
      {
        'A' => {
          cell_id: 'A',
          nodes: [{ point: p(1, 1) }.freeze, { point: p(2, 2) }.freeze].freeze,
          edges: [[0, 1].freeze].freeze
        }.freeze
      }
    )
    model
  end

  def test_off_mode_hides_one_shot_native_points
    Core::ReferenceGraphDebugMode.instance_variable_set(:@mode, :off)
    assert_empty build_model.debug_reference_points_by_kind
  end

  def test_native_snapshot_points_have_no_radius_or_protected_radius_style
    Core::ReferenceGraphDebugMode.instance_variable_set(:@mode, :before)
    grouped = build_model.debug_reference_points_by_kind
    assert_equal [{ cell_id: 'A', point: p(1, 1) },
                  { cell_id: 'A', point: p(2, 2) }], grouped[4]
    refute grouped.key?(5)
  end

  def test_renderer_draws_radius_free_reference_points
    model = Struct.new(:debug_reference_points_by_kind).new(
      { 4 => [{ cell_id: 'A', point: p(2, 1) }] }
    )
    render = Renderer.new(indoor_model: model, transform_context: Object.new.tap do |transform|
      def transform.overlay_cell_reference_points(points, cell_id)
        return [] unless cell_id == 'A'
        points
      end
    end)
    view = View.new
    render.draw(view)
    assert_equal 1, view.points.length
    assert_equal 5, view.points.last[:style]
    assert_equal 8, view.points.last[:size]
    assert_equal [p(2, 1)], view.points.last[:points]
  end

  def teardown
    Core::ReferenceGraphDebugMode.instance_variable_set(:@mode, :off)
  end
end
