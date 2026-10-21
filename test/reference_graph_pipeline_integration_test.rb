# frozen_string_literal: true

require 'minitest/autorun'

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
    end
  end
end

require_relative '../indoor3d/application/adjacency_service/native_bridge'
require_relative '../indoor3d/application/adjacency_service/reference_graph_debug_mode'
require_relative '../indoor3d/application/indoor_model/cell_space_batch_lifecycle'

class ReferenceGraphPipelineIntegrationTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Bridge = Core::NativeAdjacencyBridge
  Mode = Core::ReferenceGraphDebugMode
  Lifecycle = Core::IndoorModel::CellSpaceBatchLifecycle
  Cell = Struct.new(:id) do
    def valid? = true
  end
  Registry = Struct.new(:cell_spaces)

  class Harness
    include Lifecycle

    def initialize(cells)
      @feature_registry = Registry.new(cells)
      @debug_reference_graph_overlay_by_cell_id = {}
    end
  end

  def setup
    @original_reference_graph = Bridge.method(:reference_graph)
    Bridge.define_singleton_method(:reference_graph) do |cell_id, stage|
      next nil unless cell_id == 'cell-1'

      {
        nodes: [[0.0, 0.0, 1.0], [1.0, 0.0, 1.0]].freeze,
        edges: [[0, 1].freeze].freeze,
        requested_stage: stage
      }.freeze
    end
    Mode.instance_variable_set(:@mode, :off)
    Mode.remove_instance_variable(:@selection_highlight_enabled) if Mode.instance_variable_defined?(:@selection_highlight_enabled)
  end

  def teardown
    original = @original_reference_graph
    Bridge.define_singleton_method(:reference_graph) do |*args|
      original.call(*args)
    end
    Mode.instance_variable_set(:@mode, :off)
    Mode.remove_instance_variable(:@selection_highlight_enabled) if Mode.instance_variable_defined?(:@selection_highlight_enabled)
  end

  def test_overlay_is_off_until_an_explicit_native_stage_query
    lifecycle = Harness.new([Cell.new('cell-1')])
    assert_empty lifecycle.debug_reference_graphs
    assert_empty lifecycle.debug_reference_points_by_kind

    assert_equal 1, lifecycle.request_reference_graph_debug(:collapsed)
    Mode.instance_variable_set(:@mode, :collapsed)
    graph = lifecycle.debug_reference_graphs.fetch(0)
    assert_equal [[0, 1]], graph[:edges]
    assert_equal 'cell-1', graph[:cell_id]
    assert_equal [{ cell_id: 'cell-1', point: graph[:nodes][0][:point] },
                  { cell_id: 'cell-1', point: graph[:nodes][1][:point] }],
                 lifecycle.debug_reference_points_by_kind.fetch(4)
    assert graph[:nodes].all? { |node| node.keys == [:point] }
    refute graph[:nodes].any? { |node| node.key?(:radius) }
  end

  def test_connectivity_repair_stage_preserves_per_cell_debug_ownership
    lifecycle = Harness.new([Cell.new('cell-1')])
    active_model = Mode.method(:active_indoor_model)
    Mode.define_singleton_method(:active_indoor_model) { lifecycle }

    assert_equal :connectivity_repair, RG.connectivity_repair!
    assert Mode.connectivity_repair?
    graph = lifecycle.debug_reference_graphs.fetch(0)
    assert_equal :connectivity_repair, graph[:stage]
    assert_equal 'cell-1', graph[:cell_id]
    RG.clear!
    assert_empty lifecycle.debug_reference_graphs
  ensure
    Mode.define_singleton_method(:active_indoor_model) { active_model.call }
    Mode.singleton_class.send(:private, :active_indoor_model)
  end

  def test_los_graph_command_renders_a_separate_native_stage
    lifecycle = Harness.new([Cell.new('cell-1')])
    active_model = Mode.method(:active_indoor_model)
    Mode.define_singleton_method(:active_indoor_model) { lifecycle }

    assert_equal :los_graph, RG.los_graph!
    assert Mode.los_graph?
    graph = lifecycle.debug_reference_graphs.fetch(0)
    assert_equal :los_graph, graph[:stage]
    assert_equal 'cell-1', graph[:cell_id]
    assert_equal [[0, 1]], graph[:edges]
    RG.clear!
    assert_empty lifecycle.debug_reference_graphs
  ensure
    Mode.define_singleton_method(:active_indoor_model) { active_model.call }
    Mode.singleton_class.send(:private, :active_indoor_model)
  end

  def test_short_path_graph_command_uses_final_tree_snapshot_without_rebuilding
    lifecycle = Harness.new([Cell.new('cell-1')])
    active_model = Mode.method(:active_indoor_model)
    Mode.define_singleton_method(:active_indoor_model) { lifecycle }

    assert_same Mode, ::RG
    assert_equal :short_path_graph, RG.short_path_graph!
    assert_equal :short_path_graph, Mode.mode
    graph = lifecycle.debug_reference_graphs.fetch(0)
    assert_equal :short_path_graph, graph[:stage]
    assert_equal [[0, 1]], graph[:edges]
    assert_equal 'cell-1', graph[:cell_id]
    assert_equal 2, lifecycle.debug_reference_points_by_kind.fetch(4).length

    RG.clear!
    assert_empty lifecycle.debug_reference_graphs
  ensure
    Mode.define_singleton_method(:active_indoor_model) { active_model.call }
    Mode.singleton_class.send(:private, :active_indoor_model)
  end

  def test_clear_removes_the_one_shot_overlay_snapshot
    lifecycle = Harness.new([Cell.new('cell-1')])
    lifecycle.request_reference_graph_debug(:optimized)
    Mode.instance_variable_set(:@mode, :optimized)
    refute_empty lifecycle.debug_reference_graphs

    lifecycle.clear_reference_graph_debug
    Mode.instance_variable_set(:@mode, :off)
    assert_empty lifecycle.debug_reference_graphs
  end

  def test_selected_cellspace_highlight_toggle_is_independent_of_graph_mode
    assert RG.highlight?
    Mode.instance_variable_set(:@mode, :optimized)

    output, = capture_io do
      refute RG.highlight_off!
      refute RG.highlight?
      assert_equal :optimized, RG.mode
      assert RG.highlight_on!
      assert RG.highlight?
      refute RG.toggle_highlight!
      refute RG.highlight?
      assert RG.toggle_highlight!
      assert RG.highlight?
    end

    assert_empty output, 'Console commands should return status without printing during release operation'
    assert_equal :optimized, RG.mode
    Mode.instance_variable_set(:@mode, :off)
    refute RG.highlight_off!
    RG.clear!
    refute RG.highlight?, 'Clearing Ref-Graph stage must not turn selection highlighting on'
  end

  def test_only_native_stage_names_are_accepted
    lifecycle = Harness.new([Cell.new('cell-1')])
    assert_raises(ArgumentError) { lifecycle.request_reference_graph_debug(:internal) }
    assert_raises(ArgumentError) { lifecycle.request_reference_graph_debug(:after) }
  end
end
