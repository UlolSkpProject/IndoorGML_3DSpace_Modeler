# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/adjacency_service/reference_graph_simplifier'
require_relative '../indoor3d/application/adjacency_service/reference_graph_loop_collapser'
require_relative '../indoor3d/application/adjacency_service/reference_graph_shortcut_optimizer'
require_relative '../indoor3d/application/adjacency_service/reference_graph_debug_mode'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceLifecycleContext; end
      class CellSpaceLifecycleLocalGridContext; end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_batch_lifecycle'

class ReferenceGraphPipelineIntegrationTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Simplifier = Core::ReferenceGraphSimplifier
  Collapser = Core::ReferenceGraphLoopCollapser
  Optimizer = Core::ReferenceGraphShortcutOptimizer
  Mode = Core::ReferenceGraphDebugMode
  Lifecycle = Core::IndoorModel::CellSpaceBatchLifecycle
  Point = Struct.new(:x, :y, :z)
  Cell = Struct.new(:id) do
    def valid?
      true
    end
  end
  Registry = Struct.new(:cell_spaces)

  class LifecycleHarness
    include Lifecycle

    def initialize(cell, before:, after:, collapsed:, optimized:, internal:)
      @feature_registry = Registry.new([cell])
      @debug_reference_graph_by_cell_id = { cell.id => before }
      @debug_reference_graph_simplified_by_cell_id = { cell.id => after }
      @debug_reference_graph_collapsed_by_cell_id = { cell.id => collapsed }
      @debug_reference_graph_optimized_by_cell_id = { cell.id => optimized }
      @room_internal_graph_by_cell_id = { cell.id => internal }
    end
  end

  def point(x, y)
    Point.new(x.to_f, y.to_f, 0.5)
  end

  def node(x, y)
    { point: point(x, y), radius: 0.1 }.freeze
  end

  def certified_loop_graph
    partitions = [{ outer: [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0]], holes: [] }.freeze].freeze
    certificate = {
      vertices: [1, 2, 3].freeze,
      point: point(1.0, 0.7),
      radius: 0.2,
      visible_neighbors: [4, 5].freeze
    }.freeze
    {
      nodes: [node(10, 10), node(0, 0), node(2, 0), node(1, 2),
              node(-1, 0.7), node(3, 0.7)].freeze,
      edges: [[1, 2], [1, 3], [1, 4], [2, 3], [2, 5]].map(&:freeze).freeze,
      loop_candidates: [certificate].freeze,
      floor_partitions: partitions,
      protocol_version: 11
    }.freeze
  end

  def test_pipeline_preserves_partitions_and_protects_loop_representative
    before = certified_loop_graph
    before_dump = Marshal.dump(before)

    after = Simplifier.simplify(before)
    after_dump = Marshal.dump(after)
    collapsed = Collapser.collapse(after, before[:loop_candidates])
    collapsed_dump = Marshal.dump(collapsed)
    optimized = Optimizer.optimize(collapsed, los_validator: ->(*) { true })

    assert_equal before_dump, Marshal.dump(before)
    assert_equal after_dump, Marshal.dump(after)
    assert_equal collapsed_dump, Marshal.dump(collapsed)
    [after, collapsed, optimized].each do |stage|
      assert_equal before[:floor_partitions], stage[:floor_partitions]
      assert_equal before[:loop_candidates], stage[:loop_candidates]
      assert_equal 11, stage[:protocol_version]
    end
    assert_equal 1, collapsed[:collapse_count]
    representative = collapsed[:nodes].find { |record| record[:protection_reason] == :certified_loop_representative }
    refute_nil representative
    assert_equal true, representative[:protected]
    assert_equal 0, optimized[:shortcut_removed_count]
    assert optimized[:nodes].any? { |record| record[:protection_reason] == :certified_loop_representative }
  end

  def test_debug_modes_return_the_matching_pipeline_snapshot
    cell = Cell.new('cell-1')
    snapshots = %i[before after collapsed optimized internal].to_h do |stage|
      [stage, { stage: stage }.freeze]
    end
    lifecycle = LifecycleHarness.new(cell, **snapshots)

    capture_io do
      %i[before after collapsed optimized internal].each do |stage|
        Mode.public_send("#{stage}!")
        assert_same snapshots[stage], lifecycle.debug_reference_graphs.fetch(0)
      end
    end
  ensure
    capture_io { Mode.before! }
  end
end
