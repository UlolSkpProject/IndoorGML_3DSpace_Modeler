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

require_relative '../indoor3d/application/adjacency_service/reference_graph_simplifier'
require_relative '../indoor3d/application/adjacency_service/reference_graph_debug_mode'
require_relative '../indoor3d/application/indoor_model/cell_space_batch_lifecycle'
require_relative '../indoor3d/ui/overlays/renderers/reference_point_debug_overlay_renderer'

class ReferencePointProtectedOverlayTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Renderer = Core::ReferencePointDebugOverlayRenderer
  Point = Geom::Point3d
  CellSpace = Struct.new(:id) do
    def valid?; true; end
  end

  class View
    attr_reader :points
    def initialize; @points = []; end
    def draw_points(points, size, style, color)
      @points << { points: points, size: size, style: style, color: color }
    end
  end

  def p(x, y)
    Point.new(x, y, 5)
  end

  def nodes
    [p(0, 0), p(1, 1), p(2, 1), p(1.5, 2), p(3, 2), p(9, 9)].map do |point|
      { point: point, radius: 1.0 }.freeze
    end
  end

  def build_model
    graph = {
      nodes: nodes.freeze,
      edges: [[0, 1], [1, 2], [1, 3], [2, 3], [3, 4]].map(&:freeze).freeze,
      loop_candidates: [{ vertices: [1, 2, 3] }].freeze
    }.freeze
    after = graph.merge(original_indices: (0..5).to_a.freeze).freeze
    originals = graph[:nodes].map { |node| { point: node[:point], kind: 4 }.freeze }
    originals << { point: p(10, 10), kind: 1 }.freeze
    model = Core::IndoorModel.allocate
    model.extend(Core::IndoorModel::CellSpaceBatchLifecycle)
    registry = Struct.new(:cell_spaces).new([CellSpace.new('A')])
    model.instance_variable_set(:@feature_registry, registry)
    model.instance_variable_set(:@debug_reference_graph_by_cell_id, { 'A' => graph })
    model.instance_variable_set(:@debug_reference_graph_simplified_by_cell_id, { 'A' => after })
    model.instance_variable_set(:@debug_reference_points_by_cell_id, { 'A' => originals })
    model
  end

  def test_before_colors_only_protected_final_references
    Core::ReferenceGraphDebugMode.instance_variable_set(:@mode, :before)
    grouped = build_model.debug_reference_points_by_kind
    assert_equal [p(1, 1), p(2, 1), p(1.5, 2), p(3, 2)], grouped[5]
    assert_equal [p(0, 0), p(9, 9)], grouped[4]
    assert_equal [p(10, 10)], grouped[1]
  end

  def test_after_uses_original_indices_for_same_protection
    Core::ReferenceGraphDebugMode.instance_variable_set(:@mode, :after)
    grouped = build_model.debug_reference_points_by_kind
    assert_equal [p(1, 1), p(2, 1), p(1.5, 2), p(3, 2)], grouped[5]
    assert_equal [p(9, 9)], grouped[4]
    refute_includes Array(grouped[5]), p(0, 0)
  end

  def test_new_collapsed_representative_is_marked_when_nil_origin
    Core::ReferenceGraphDebugMode.instance_variable_set(:@mode, :collapsed)
    model = build_model
    collapsed = model.instance_variable_get(:@debug_reference_graph_simplified_by_cell_id)['A'].dup
    collapsed[:nodes] = collapsed[:nodes] + [{ point: p(7, 7), radius: 1.0, protected: true }.freeze]
    collapsed[:original_indices] = (0..5).to_a + [nil]
    model.instance_variable_set(:@debug_reference_graph_collapsed_by_cell_id, { 'A' => collapsed.freeze })
    assert_includes model.debug_reference_points_by_kind[5], p(7, 7)
  end

  def test_renderer_uses_contrasting_magenta_x_and_preserves_normal_style
    model = Struct.new(:debug_reference_points_by_kind).new({
      1 => [p(10, 10)], 4 => [p(9, 9)], 5 => [p(2, 1)]
    })
    render = Renderer.new(indoor_model: model, transform_context: Object.new.tap do |transform|
      def transform.overlay_render_points(points); points; end
    end)
    view = View.new
    render.draw(view)
    assert_equal 3, view.points.length
    assert_equal [2, 5, 4], view.points.map { |item| item[:style] }
    assert_equal [8, 8, 14], view.points.map { |item| item[:size] }
    assert_equal Sketchup::Color.new(235, 20, 145), view.points.last[:color]
    assert_equal [p(2, 1)], view.points.last[:points]
  end

  def test_protected_only_is_still_drawn
    model = Struct.new(:debug_reference_points_by_kind).new({ 5 => [p(1, 1)] })
    render = Renderer.new(indoor_model: model, transform_context: Object.new.tap do |transform|
      def transform.overlay_render_points(points); points; end
    end)
    view = View.new
    render.draw(view)
    assert_equal 1, view.points.length
    assert_equal 4, view.points.last[:style]
    assert_equal [p(1, 1)], view.points.last[:points]
  end

  def test_protection_cache_reuses_immutable_source_and_refreshes_on_replacement
    model = build_model
    source = model.instance_variable_get(:@debug_reference_graph_by_cell_id)['A']
    one = model.send(:protected_reference_visuals_for, 'A', source)
    two = model.send(:protected_reference_visuals_for, 'A', source)
    assert_same one[0], two[0]
    assert_same one[1], two[1]

    replacement = source.merge(loop_candidates: [].freeze).freeze
    three = model.send(:protected_reference_visuals_for, 'A', replacement)
    refute_same one[0], three[0]
    refute three[0][2]  # Prior loop vertex is no longer protected.
    assert three[0][0] # State remains protected.
  end

  def teardown
    Core::ReferenceGraphDebugMode.instance_variable_set(:@mode, :before)
  end
end
