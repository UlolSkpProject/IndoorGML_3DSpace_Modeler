# frozen_string_literal: true

require 'minitest/autorun'

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def transform(transformation)
      transformation.transform_point(self)
    end

    def distance(other)
      Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    end
  end

  class Transformation
    attr_reader :angle, :x, :y, :z

    def initialize(values = nil)
      values ||= self.class.values(0.0, 0.0, 0.0, 0.0)
      @angle = Math.atan2(values[1].to_f, values[0].to_f)
      @x = values[12].to_f
      @y = values[13].to_f
      @z = values[14].to_f
    end

    def self.translation(x, y = 0.0, z = 0.0)
      rigid(0.0, x, y, z)
    end

    def self.rigid(angle, x, y, z = 0.0)
      new(values(angle, x, y, z))
    end

    def self.values(angle, x, y, z)
      cosine = Math.cos(angle)
      sine = Math.sin(angle)
      [
        cosine, sine, 0.0, 0.0,
        -sine, cosine, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        x.to_f, y.to_f, z.to_f, 1.0
      ]
    end

    def *(other)
      cosine = Math.cos(angle)
      sine = Math.sin(angle)
      self.class.rigid(
        angle + other.angle,
        x + (cosine * other.x) - (sine * other.y),
        y + (sine * other.x) + (cosine * other.y),
        z + other.z
      )
    end

    def inverse
      cosine = Math.cos(angle)
      sine = Math.sin(angle)
      self.class.rigid(
        -angle,
        (-cosine * x) - (sine * y),
        (sine * x) - (cosine * y),
        -z
      )
    end

    def origin
      Point3d.new(x, y, z)
    end

    def transform_point(point)
      cosine = Math.cos(angle)
      sine = Math.sin(angle)
      Point3d.new(
        x + (cosine * point.x) - (sine * point.y),
        y + (sine * point.x) + (cosine * point.y),
        z + point.z
      )
    end

    def to_a
      self.class.values(angle, x, y, z)
    end
  end
end

module Sketchup
  class << self
    attr_accessor :active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      class IndoorModel; end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/observer_routing'

class PrimalAxesTransitionRebuildTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore
  Frame = Geom::Transformation

  View = Struct.new(:invalidations) do
    def invalidate
      self.invalidations += 1
    end
  end
  Model = Struct.new(:active_view)
  Entity = Struct.new(:transformation) do
    def valid? = true
  end
  Group = Struct.new(:transformation) do
    def valid? = true
  end
  Cell = Struct.new(:id, :sketchup_group) do
    def valid? = true
    def valid_sketchup_group = sketchup_group
  end
  Transition = Struct.new(:id, :cell1, :cell2, :state1_point, :state2_point) do
    def valid? = true
  end

  class Harness
    include Core::IndoorModel::ObserverRouting

    attr_reader :clears, :render_invalidations, :rebuilt_ids, :remembered

    def initialize(cells, transitions, previous_cell_frames)
      @cell_spaces = cells
      @transitions = transitions
      @previous_cell_frames = previous_cell_frames
      @clears = 0
      @render_invalidations = 0
      @rebuilt_ids = []
      @remembered = 0
    end

    def cell_space_change_snapshot_for(group)
      values = @previous_cell_frames[group]
      values && { transformation: values.to_a }
    end

    def cell_space_root_local_transformation(cell_space)
      cell_space.sketchup_group.transformation
    end

    def reject_scaled_space_features_transform(_entity)
      false
    end

    def update_transition(transition)
      @rebuilt_ids << transition.id
      true
    end

    def clear_overlay_transition_cache
      @clears += 1
    end

    def invalidate_overlay_primal_render_transform
      @render_invalidations += 1
    end

    def remember_space_features_change_snapshot(_entity)
      @remembered += 1
    end
  end

  def setup
    @previous_root = Frame.rigid(Math::PI / 9, 10.0, -4.0)
    @current_root = Frame.rigid(-Math::PI / 5, 30.0, 12.0)
    @previous_cell_frames = [
      Frame.rigid(Math::PI / 7, 100.0, 20.0),
      Frame.rigid(-Math::PI / 8, 200.0, -25.0)
    ]
    @cells = @previous_cell_frames.each_with_index.map do |frame, index|
      Cell.new("cell-#{index + 1}", Group.new(frame))
    end
    @transitions = [
      Transition.new(
        'transition-1', @cells[0], @cells[1],
        @previous_cell_frames[0].origin, @previous_cell_frames[1].origin
      )
    ]
    @view = View.new(0)
    Sketchup.active_model = Model.new(@view)
  end

  def test_change_axes_is_detected_when_child_frames_are_inverse_rebased
    apply_inverse_rebase_to_cells
    harness = build_harness

    assert harness.send(:primal_axes_rebased?, previous_snapshot, current_snapshot)
  end

  def test_stored_transition_endpoints_detect_change_axes_without_child_snapshots
    apply_inverse_rebase_to_cells
    harness = Harness.new(@cells, @transitions, {})

    assert harness.send(:primal_axes_rebased?, previous_snapshot, current_snapshot)
  end

  def test_rigid_primal_motion_is_not_classified_as_change_axes
    harness = build_harness

    refute harness.send(:primal_axes_rebased?, previous_snapshot, current_snapshot)
  end

  def test_change_axes_rebuilds_transition_inputs_and_clears_all_curve_caches
    apply_inverse_rebase_to_cells
    harness = build_harness

    assert harness.send(
      :handle_space_features_transform_changed,
      Entity.new(@current_root),
      previous_snapshot: previous_snapshot,
      current_snapshot: current_snapshot
    )
    assert_equal ['transition-1'], harness.rebuilt_ids
    assert_equal 1, harness.clears
    assert_equal 0, harness.render_invalidations
    assert_equal 1, harness.remembered
    assert_equal 1, @view.invalidations
  end

  def test_rigid_primal_motion_only_invalidates_the_world_render_transform
    harness = build_harness

    assert harness.send(
      :handle_space_features_transform_changed,
      Entity.new(@current_root),
      previous_snapshot: previous_snapshot,
      current_snapshot: current_snapshot
    )
    assert_empty harness.rebuilt_ids
    assert_equal 0, harness.clears
    assert_equal 1, harness.render_invalidations
    assert_equal 1, harness.remembered
    assert_equal 1, @view.invalidations
  end

  private

  def apply_inverse_rebase_to_cells
    rebase = @current_root.inverse * @previous_root
    @cells.each_with_index do |cell, index|
      cell.sketchup_group.transformation = rebase * @previous_cell_frames[index]
    end
  end

  def build_harness
    previous_frames = @cells.each_with_index.to_h do |cell, index|
      [cell.sketchup_group, @previous_cell_frames[index]]
    end
    Harness.new(@cells, @transitions, previous_frames)
  end

  def previous_snapshot
    { transformation: @previous_root.to_a }
  end

  def current_snapshot
    { transformation: @current_root.to_a }
  end
end
