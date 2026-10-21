# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/indoor_model/editor_control'

class DualGraphSelectionCacheTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Selection = Struct.new(:entities) do
    def each(&block)
      @enumerations = @enumerations.to_i + 1
      entities.each(&block)
    end

    def enumerations
      @enumerations.to_i
    end
  end
  SketchupModel = Struct.new(:selection)
  Group = Struct.new(:name) do
    def valid?
      true
    end
  end
  Cell = Struct.new(:id, :group, :active) do
    def valid?
      active != false
    end

    def valid_sketchup_group
      group
    end
  end

  class IndoorModelHarness
    include Core::IndoorModel::EditorControl
    attr_reader :primal_group
    attr_accessor :editing

    def initialize(model:, primal_group:, cells:)
      @model = model
      @primal_group = primal_group
      @cell_spaces = cells
      @editing = true
    end

    def editing?
      @editing
    end
  end

  def setup
    @primal = Group.new('PrimalSpaceFeatures')
    @a = Group.new('cell-a')
    @b = Group.new('cell-b')
    @selection = Selection.new([@a])
    @cells = [Cell.new('A', @a, true), Cell.new('B', @b, true)]
    @indoor_model = IndoorModelHarness.new(
      model: SketchupModel.new(@selection),
      primal_group: @primal,
      cells: @cells
    )
  end

  def test_event_snapshot_is_immutable_and_never_reads_selection_on_camera_draw
    snapshot = @indoor_model.refresh_dual_graph_selection_cache
    assert_equal({ 'A' => true }, snapshot[:cell_ids])
    assert_equal [@a], snapshot[:entities]
    assert snapshot.frozen?
    assert snapshot[:cell_ids].frozen?

    enumerations = @selection.enumerations
    100.times do
      assert_same snapshot, @indoor_model.dual_graph_selection_snapshot
      assert_equal({ 'A' => true }, @indoor_model.dual_graph_selection_snapshot[:cell_ids])
    end
    assert_equal enumerations, @selection.enumerations
  end

  def test_selection_event_updates_multi_selection_and_primal_transform_watcher
    @indoor_model.refresh_dual_graph_selection_cache
    @selection.entities = [@a, @b, @primal]
    snapshot = @indoor_model.refresh_dual_graph_selection_cache

    assert_equal({ 'A' => true, 'B' => true }, snapshot[:cell_ids])
    assert_equal [@primal, @a, @b], snapshot[:entities]
    assert_equal [:primal, :cell, :cell], snapshot[:watched_groups].map { |w| w[:kind] }
    assert_equal [nil, 'A', 'B'], snapshot[:watched_groups].map { |w| w[:cell_id] }

    @selection.entities = []
    assert_equal({ 'A' => true, 'B' => true }, @indoor_model.dual_graph_selection_snapshot[:cell_ids])
    assert_empty @indoor_model.refresh_dual_graph_selection_cache[:cell_ids]
  end

  def test_only_identical_registered_groups_are_selected
    @selection.entities = [Group.new('cell-a'), Group.new('cell-b')]
    assert_empty @indoor_model.refresh_dual_graph_selection_cache[:cell_ids]

    @selection.entities = [@a, @b]
    @cells[1].active = false
    assert_equal({ 'A' => true }, @indoor_model.refresh_dual_graph_selection_cache[:cell_ids])
  end

  def test_explicit_topology_refresh_reconciles_group_replacement
    @indoor_model.refresh_dual_graph_selection_cache
    replacement = Group.new('cell-a')
    @cells[0].group = replacement

    assert_equal({ 'A' => true }, @indoor_model.dual_graph_selection_snapshot[:cell_ids])
    assert_empty @indoor_model.refresh_dual_graph_selection_cache[:cell_ids]

    @selection.entities = [replacement]
    assert_equal({ 'A' => true }, @indoor_model.refresh_dual_graph_selection_cache[:cell_ids])
  end

  def test_end_editing_clears_snapshot
    @indoor_model.refresh_dual_graph_selection_cache
    @indoor_model.editing = false
    assert_empty @indoor_model.refresh_dual_graph_selection_cache[:cell_ids]
    assert_empty @indoor_model.dual_graph_selection_snapshot[:entities]
  end
end
