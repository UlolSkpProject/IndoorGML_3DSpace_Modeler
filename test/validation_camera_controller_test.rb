# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/infrastructure/scene/editor_session/validation_camera_controller'

module Geom
end unless defined?(Geom)

unless defined?(Geom::Point3d)
  module Geom
    class Point3d
      attr_reader :x, :y, :z

      def initialize(x, y, z)
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
      end
    end

    class Vector3d < Point3d
    end
  end
end

class ValidationCameraControllerTest < Minitest::Test
  class FakeCamera
    attr_accessor :perspective, :height, :aspect_ratio
    attr_reader :eye, :target, :up, :fov

    def initialize(eye:, target:, up:, perspective:, fov: 35.0, height: 10.0, aspect_ratio: 0.0)
      @eye = point(eye)
      @target = point(target)
      @up = vector(up)
      @perspective = perspective
      @fov = fov
      @height = height
      @aspect_ratio = aspect_ratio
    end

    def perspective?
      @perspective == true
    end

    def set(eye, target, up)
      @eye = eye
      @target = target
      @up = up
    end

    def xaxis
      front = coordinates(zaxis)
      up = coordinates(yaxis)
      vector(
        [
          front[1] * up[2] - front[2] * up[1],
          front[2] * up[0] - front[0] * up[2],
          front[0] * up[1] - front[1] * up[0]
        ]
      )
    end

    def yaxis
      vector(normalize(coordinates(@up)))
    end

    def zaxis
      vector(normalize(subtract(coordinates(@target), coordinates(@eye))))
    end

    def copy
      self.class.new(
        eye: coordinates(@eye),
        target: coordinates(@target),
        up: coordinates(@up),
        perspective: perspective?,
        fov: @fov,
        height: @height,
        aspect_ratio: @aspect_ratio
      )
    end

    def test_snapshot_is_deep_copy_and_preserves_parallel_height_through_multiple_rows
    original = camera(perspective: false)
    original.height = 61.0
    model = FakeModel.new(original)
    target_controller = controller
    assert target_controller.capture(model)[:ok]

    3.times do |i|
      result = target_controller.apply(
        model, orientation: :iso, zoom: :bounds,
        target: { min: [i, -2, -3], max: [i + 10, 10, 11] }
      )
      assert result[:ok], result[:message]
    end

    restored = target_controller.restore
    assert restored[:ok]
    assert_in_delta 61.0, model.active_view.camera.height, 1.0e-12
    refute_same original, model.active_view.camera
    assert target_controller.capture(model)[:ok]
  end

  def test_explicit_perspective_frame_preserves_fov
    model = FakeModel.new(camera(perspective: false))
    result = controller.apply(
      model, orientation: :top, projection: :perspective, zoom: :bounds,
      target: { min: [-20, -10, -1], max: [20, 10, 1] }
    )
    assert result[:ok], result[:message]
    assert model.active_view.camera.perspective?
    assert_in_delta 35.0, model.active_view.camera.fov
    assert model.active_view.camera.eye.z > 0
  end

  def test_keep_projection_and_orientation
    original = camera(perspective: true)
    model = FakeModel.new(original)
    result = controller.apply(model, projection: :keep, orientation: :keep, zoom: :none)
    assert result[:ok], result[:message]
    assert model.active_view.camera.perspective?
    assert_in_delta original.eye.x, model.active_view.camera.eye.x
  end

  def test_portrait_viewport_requires_larger_parallel_height
    bounds = { min: [-10, -3, -2], max: [10, 3, 2] }
    landscape = FakeModel.new(camera(perspective: false))
    portrait = FakeModel.new(camera(perspective: false))
    portrait.active_view.define_singleton_method(:vpwidth) { 300 }
    portrait.active_view.define_singleton_method(:vpheight) { 1200 }

    assert controller.apply(landscape, zoom: :bounds, target: bounds)[:ok]
    assert controller.apply(portrait, zoom: :bounds, target: bounds)[:ok]
    assert portrait.active_view.camera.height > landscape.active_view.camera.height
  end

  def test_flat_bounds_and_tiny_bounds_are_safe
    model = FakeModel.new(camera(perspective: false))
    target_controller = controller
    [{ min: [-20, -10, 0], max: [20, 10, 0] },
     { min: [0, 0, 0], max: [0, 0, 0] }].each do |bounds|
      result = target_controller.apply(model, zoom: :bounds, target: bounds)
      assert result[:ok], result[:message]
      assert model.active_view.camera.height.positive?
      assert model.active_view.camera.height.finite?
    end
  end

  def test_invalid_bounds_projection_margin_and_empty_selection_do_not_capture
    model = FakeModel.new(camera(perspective: true))
    target_controller = controller
    bad = [
      { projection: :bad },
      { margin: 0 },
      { zoom: :bounds, target: { min: [3, 0, 0], max: [2, 1, 1] } },
      { zoom: :bounds, target: { min: [Float::NAN, 0, 0], max: [1, 1, 1] } },
      { zoom: :selected, target: [] }
    ]
    bad.each do |options|
      result = target_controller.apply(model, **options)
      refute result[:ok]
      refute target_controller.captured_model?(model)
    end
  end

  def test_camera_failure_rolls_back_without_mutating_original
    original = camera(perspective: true)
    model = FakeModel.new(original)
    target_controller = controller
    assert target_controller.capture(model)[:ok]
    working = model.active_view.camera
    working.define_singleton_method(:set) { |_eye, _target, _up| raise 'Camera set failed' }
    result = target_controller.apply(model, zoom: :bounds,
                                     target: { min: [0, 0, 0], max: [2, 2, 2] })
    refute result[:ok]
    assert model.active_view.camera.perspective?
    assert_in_delta original.eye.x, model.active_view.camera.eye.x
    refute target_controller.captured_model?(model)
  end

  def test_invalid_model_does_not_capture
    model = FakeModel.new(camera(perspective: true))
    model.define_singleton_method(:valid?) { false }
    result = controller.capture(model)
    refute result[:ok]
  end

  def test_restore_failure_can_be_retried_without_losing_snapshot
    model = FakeModel.new(camera(perspective: false))
    target_controller = controller
    assert target_controller.capture(model)[:ok]
    view = model.active_view
    view.instance_variable_set(:@fail_next_camera_assignment, true)
    view.define_singleton_method(:camera=) do |camera_value|
      if @fail_next_camera_assignment
        @fail_next_camera_assignment = false
        raise 'temporary failure'
      end
      @camera = camera_value
    end

    failed = target_controller.restore
    refute failed[:ok]
    assert target_controller.captured_model?(model)

    restored = target_controller.restore
    assert restored[:ok]
    assert restored[:restored]
    refute target_controller.captured_model?(model)
  end

  private

    def point(values)
      coordinates = coordinates(values)
      Geom::Point3d.new(*coordinates)
    end

    def vector(values)
      coordinates = coordinates(values)
      Geom::Vector3d.new(*coordinates)
    end

    def coordinates(value)
      return [value.x.to_f, value.y.to_f, value.z.to_f] if value.respond_to?(:x)

      Array(value).map(&:to_f)
    end

    def subtract(first, second)
      [first[0] - second[0], first[1] - second[1], first[2] - second[2]]
    end

    def normalize(values)
      length = Math.sqrt(values.sum { |value| value * value })
      values.map { |value| value / length }
    end
  end

  class FakeView
    attr_accessor :camera
    attr_reader :zoomed, :zoom_extents_count, :invalidate_count

    def initialize(camera)
      @camera = camera
      @zoom_extents_count = 0
      @invalidate_count = 0
    end

    def zoom(target)
      @zoomed = target
    end

    def zoom_extents
      @zoom_extents_count += 1
    end

    def invalidate
      @invalidate_count += 1
    end

    def vpwidth
      1600
    end

    def vpheight
      900
    end
  end

  class FakeModel
    attr_reader :active_view, :selection

    def initialize(camera)
      @active_view = FakeView.new(camera)
      @selection = []
    end

    def valid?
      true
    end
  end

  def test_apply_uses_parallel_working_camera_and_restore_recovers_original
    original = camera(perspective: true)
    model = FakeModel.new(original)
    target_controller = controller

    result = target_controller.apply(model)

    assert result[:ok]
    assert result[:projection_changed]
    refute_same original, model.active_view.camera
    refute model.active_view.camera.perspective?

    restored = target_controller.restore

    assert restored[:ok]
    assert restored[:restored]
    refute_same original, model.active_view.camera
    assert model.active_view.camera.perspective?
    assert_in_delta original.eye.x, model.active_view.camera.eye.x
    assert_in_delta original.eye.y, model.active_view.camera.eye.y
    assert_in_delta original.eye.z, model.active_view.camera.eye.z
  end

  def test_same_model_reuses_working_camera_and_skips_matching_orientation
    model = FakeModel.new(camera(perspective: true))
    target_controller = controller

    first = target_controller.apply(model, orientation: :top)
    working_camera = model.active_view.camera
    second = target_controller.apply(model, orientation: :top)

    assert first[:orientation_changed]
    refute second[:orientation_changed]
    assert_same working_camera, model.active_view.camera
  end

  def test_model_switch_discards_old_snapshot_without_writing_into_old_model
    model_a = FakeModel.new(camera(perspective: true))
    model_b = FakeModel.new(camera(perspective: false))
    target_controller = controller

    target_controller.apply(model_a, orientation: :top)
    old_working = model_a.active_view.camera
    target_controller.apply(model_b, orientation: :iso)

    assert_same old_working, model_a.active_view.camera
    assert target_controller.captured_model?(model_b)
    refute target_controller.captured_model?(model_a)

    target_controller.restore
    assert model_b.active_view.camera.fov == 35.0
    assert_same old_working, model_a.active_view.camera
  end

  def test_orientation_presets_match_sketchup_camera_axes
    expectations = {
      top: { front: [0.0, 0.0, -1.0], up: [0.0, 1.0, 0.0] },
      bottom: { front: [0.0, 0.0, 1.0], up: [0.0, -1.0, 0.0] },
      front: { front: [0.0, 1.0, 0.0], up: [0.0, 0.0, 1.0] },
      back: { front: [0.0, -1.0, 0.0], up: [0.0, 0.0, 1.0] },
      left: { front: [1.0, 0.0, 0.0], up: [0.0, 0.0, 1.0] },
      right: { front: [-1.0, 0.0, 0.0], up: [0.0, 0.0, 1.0] },
      iso: {
        front: [-1.0 / Math.sqrt(3.0), 1.0 / Math.sqrt(3.0), -1.0 / Math.sqrt(3.0)],
        up: [-1.0 / Math.sqrt(6.0), 1.0 / Math.sqrt(6.0), 2.0 / Math.sqrt(6.0)]
      }
    }

    expectations.each do |orientation, expected|
      model = FakeModel.new(camera(perspective: false))
      result = controller.apply(model, orientation: orientation)

      assert result[:ok]
      assert result[:orientation_changed]
      assert_vector expected.fetch(:front), model.active_view.camera.zaxis
      assert_vector expected.fetch(:up), model.active_view.camera.yaxis
    end
  end

  def test_bounds_zoom_preserves_requested_orientation
    model = FakeModel.new(camera(perspective: false))
    bounds = {
      min: [-5.0, -3.0, -2.0],
      max: [7.0, 11.0, 13.0]
    }

    result = controller.apply(model, orientation: :iso, zoom: :bounds, target: bounds)

    assert result[:ok]
    assert result[:zoom_applied]
    assert_vector(
      [-1.0 / Math.sqrt(3.0), 1.0 / Math.sqrt(3.0), -1.0 / Math.sqrt(3.0)],
      model.active_view.camera.zaxis
    )
    assert_vector(
      [-1.0 / Math.sqrt(6.0), 1.0 / Math.sqrt(6.0), 2.0 / Math.sqrt(6.0)],
      model.active_view.camera.yaxis
    )
  end

  def test_bounds_zoom_accepts_string_keyed_hash
    model = FakeModel.new(camera(perspective: true))
    bounds = {
      'min' => [-5.0, -3.0, -2.0],
      'max' => [7.0, 11.0, 13.0]
    }

    result = controller.apply(model, orientation: :iso, zoom: :bounds, target: bounds)

    assert result[:ok], result[:message]
    assert result[:zoom_applied]
    refute model.active_view.camera.perspective?
  end

  def test_bounds_zoom_enforces_minimum_parallel_frame_height
    model = FakeModel.new(camera(perspective: false))
    target_controller = controller
    bounds = {
      min: [1.0, 1.0, 1.0],
      max: [1.0, 1.0, 1.0]
    }

    result = target_controller.apply(model, zoom: :bounds, target: bounds)

    assert result[:ok]
    assert result[:zoom_applied]
    expected = ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::ValidationCameraController::MIN_FRAME_SIZE *
               ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::ValidationCameraController::DEFAULT_MARGIN
    assert_in_delta expected, model.active_view.camera.height, 1.0e-12
  end

  def test_selected_zoom_applies_explicit_margin_to_parallel_camera_height
    model = FakeModel.new(camera(perspective: false))
    target_controller = controller
    target = Object.new

    result = target_controller.apply(model, zoom: :selected, target: target, margin: 1.4)

    assert result[:ok]
    assert result[:zoom_applied]
    assert_same target, model.active_view.zoomed
    assert_in_delta 14.0, model.active_view.camera.height, 1.0e-12
  end

  def test_selected_zoom_keeps_existing_scale_without_explicit_margin
    model = FakeModel.new(camera(perspective: false))
    target_controller = controller

    result = target_controller.apply(model, zoom: :selected, target: Object.new)

    assert result[:ok]
    assert_in_delta 10.0, model.active_view.camera.height, 1.0e-12
  end

  def test_removed_camera_aliases_are_rejected
    model = FakeModel.new(camera(perspective: false))
    target_controller = controller

    down = target_controller.apply(model, orientation: :down)
    extend = target_controller.apply(model, zoom: :extend)

    refute down[:ok]
    assert_includes down[:message], '지원하지 않는 Camera 방향'
    refute extend[:ok]
    assert_includes extend[:message], '지원하지 않는 Zoom 방식'
  end

  private

  def controller
    ULOL::Indoor3DGmlModeler::IndoorCore::EditorSession::ValidationCameraController.new(camera_factory: ->(source) { source.copy })
  end

  def camera(perspective:)
    FakeCamera.new(
      eye: [10.0, 10.0, 10.0],
      target: [0.0, 0.0, 0.0],
      up: [0.0, 0.0, 1.0],
      perspective: perspective
    )
  end

  def assert_vector(expected, actual)
    coordinates = [actual.x, actual.y, actual.z]
    expected.zip(coordinates).each do |expected_value, actual_value|
      assert_in_delta expected_value, actual_value, 1.0e-12
    end
  end
end
