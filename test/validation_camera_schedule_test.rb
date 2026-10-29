# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session'

module Sketchup
  class << self
    attr_accessor :active_model
  end
end unless defined?(Sketchup)

module UI
  @pending = []
  def self.start_timer(_delay, _repeat, &block)
    @pending << block
    @pending.length
  end

  def self.flush
    callbacks = @pending
    @pending = []
    callbacks.each(&:call)
  end

  def self.clear
    @pending = []
  end
end unless defined?(UI)

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end
  end unless const_defined?(:Point3d, false)

  class Vector3d < Point3d
  end unless const_defined?(:Vector3d, false)

  class BoundingBox
    def initialize
      @points = []
    end

    def add(point)
      @points << point
    end

    def valid?
      !@points.empty?
    end

    def min
      Point3d.new(*3.times.map { |axis| @points.map { |point| [point.x, point.y, point.z][axis] }.min })
    end

    def max
      Point3d.new(*3.times.map { |axis| @points.map { |point| [point.x, point.y, point.z][axis] }.max })
    end
  end unless const_defined?(:BoundingBox, false)
end

unless Geom::Point3d.instance_methods.include?(:transform)
  class Geom::Point3d
    def transform(frame)
      return frame.apply(self) if frame.respond_to?(:apply)

      self.class.new(x + frame.dx, y + frame.dy, z + frame.dz)
    end
  end
end

class ValidationCameraScheduleTest < Minitest::Test
  EditorSession = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession
  Translation = Struct.new(:dx, :dy, :dz)

  class Model
    attr_reader :active_view
    attr_accessor :active_path

    def initialize
      @active_view = Object.new
    end

    def valid?
      true
    end
  end

  class Focus
    attr_accessor :highlight_row_id

    def initialize
      @highlight_row_id = 'A'
    end

    def active?
      true
    end
  end

  class Recorder
    attr_reader :applied, :restores

    def initialize
      @applied = []
      @restores = 0
    end

    def capture(model)
      @model = model
      { ok: true }
    end

    def captured_model?(model)
      @model.equal?(model)
    end

    def apply(model, **options)
      @applied << [model, options]
      { ok: true }
    end

    def restore
      @restores += 1
      @model = nil
      { ok: true, restored: true }
    end
  end

  class LocalBounds
    def initialize(min, max)
      @minimum, @maximum = min, max
    end

    def valid?
      true
    end

    def corner(index)
      Geom::Point3d.new(
        (index & 1) != 0 ? @maximum[0] : @minimum[0],
        (index & 2) != 0 ? @maximum[1] : @minimum[1],
        (index & 4) != 0 ? @maximum[2] : @minimum[2]
      )
    end
  end

  class Group
    attr_reader :definition, :transformation

    def initialize(bounds, transformation)
      @definition = Struct.new(:bounds).new(bounds)
      @transformation = transformation
    end

    def valid?
      true
    end

    def parent
      nil
    end
  end

  def setup
    UI.clear
    @model = Model.new
    Sketchup.active_model = @model
    @focus = Focus.new
    @recorder = Recorder.new
    @session = EditorSession.allocate
    @session.instance_variable_set(:@indoor_model, Struct.new(:model).new(@model))
    @session.instance_variable_set(:@validation_focus_controller, @focus)
    @session.instance_variable_set(:@validation_camera_controller, @recorder)
    @session.instance_variable_set(:@validation_focus_zoom_generation, 0)
    @session.instance_variable_set(:@validation_focus_camera_session_id, 1)
    @session.define_singleton_method(:validation_focus_active?) { true }
    @session.define_singleton_method(:validation_focus_highlight_groups) { [Object.new] }
    @session.define_singleton_method(:validation_focus_bounds) do |_groups|
      { min: [0, 0, 0], max: [2, 2, 2] }
    end
  end

  def teardown
    UI.clear
    Sketchup.active_model = nil
  end

  def test_row_a_timer_must_not_override_row_b
    assert @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    @session.send(:cancel_validation_focus_zoom)
    @focus.highlight_row_id = 'B'
    assert @session.send(:zoom_validation_focus_highlight, row_id: 'B')
    UI.flush

    assert_equal 1, @recorder.applied.length
    assert_equal @model, @recorder.applied.first[0]
  end

  def test_row_immediate_deselection_cancels_pending_work
    @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    result = @session.suspend_validation_focus_camera
    UI.flush

    assert result[:ok]
    assert_empty @recorder.applied
    assert_equal 1, @recorder.restores
  end

  def test_model_switch_drops_pending_work
    @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    Sketchup.active_model = Model.new
    UI.flush

    assert_empty @recorder.applied
  end

  def test_session_switch_drops_pending_work
    @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    @session.instance_variable_set(:@validation_focus_camera_session_id, 2)
    UI.flush

    assert_empty @recorder.applied
  end

  def test_row_change_without_generation_change_is_rejected
    @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    @focus.highlight_row_id = 'B'
    UI.flush

    assert_empty @recorder.applied
  end

  def test_repeated_row_selection_cancels_previous_timer
    @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    @session.send(:cancel_validation_focus_zoom)
    @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    UI.flush

    assert_equal 1, @recorder.applied.length
  end

  def test_invalid_or_deleted_group_does_not_apply_camera
    @session.define_singleton_method(:validation_focus_highlight_groups) { [] }
    @session.send(:zoom_validation_focus_highlight, row_id: 'A')
    UI.flush

    assert_empty @recorder.applied
  end

  def test_rotated_translated_cell_uses_eight_world_corners
    local = LocalBounds.new([-3, -1, 0], [5, 2, 4])
    rotation = Object.new
    rotation.define_singleton_method(:apply) do |point|
      Geom::Point3d.new(10 - point.y, 20 + point.x, 30 + point.z)
    end
    result = @session.send(:validation_focus_bounds, [Group.new(local, rotation)])

    assert result.valid?
    assert_in_delta 8, result.min.x
    assert_in_delta 11, result.max.x
    assert_in_delta 17, result.min.y
    assert_in_delta 25, result.max.y
    assert_in_delta 30, result.min.z
    assert_in_delta 34, result.max.z
  end

  def test_local_cell_bounds_receive_world_transform_once
    local = LocalBounds.new([-2, -1, -3], [2, 1, 3])
    group = Group.new(local, Translation.new(100, 200, 300))
    result = @session.send(:validation_focus_bounds, [group])

    assert result.valid?
    assert_in_delta 98, result.min.x
    assert_in_delta 202, result.max.x
    assert_in_delta 199, result.min.y
    assert_in_delta 201, result.max.y
    assert_in_delta 297, result.min.z
    assert_in_delta 303, result.max.z
  end
end
