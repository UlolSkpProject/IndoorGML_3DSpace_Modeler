# frozen_string_literal: true

require 'minitest/autorun'

unless defined?(Sketchup::Overlay)
  module Sketchup
    class Overlay; end
  end
end

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Transformation
        def self.root_transformation_in_model(primal)
          primal.world
        end
      end
    end
  end
end

require_relative '../indoor3d/ui/overlays/space_overlay'

class ReferenceLocalOverlayFrameTest < Minitest::Test
  Overlay = ULOL::Indoor3DGmlModeler::IndoorCore::SpaceOverlay
  Point = Struct.new(:x, :y, :z) do
    def transform(frame)
      frame.apply(self)
    end
  end

  # Minimal rigid 2D XY frame for a static contract test outside SketchUp.
  class Frame
    attr_reader :angle, :x, :y
    def initialize(angle = 0, x = 0, y = 0)
      @angle, @x, @y = angle, x, y
    end

    def apply(point)
      c, s = Math.cos(angle), Math.sin(angle)
      Point.new(c * point.x - s * point.y + x,
                s * point.x + c * point.y + y, point.z)
    end

    def *(other)
      origin = apply(Point.new(other.x, other.y, 0))
      Frame.new(angle + other.angle, origin.x, origin.y)
    end
  end

  Primal = Struct.new(:world)

  class Model
    attr_accessor :primal_group, :cell_frames
    def initialize(primal, cell_frames)
      @primal_group, @cell_frames = primal, cell_frames
    end

    def reference_cell_space_transformation(cell_id)
      @cell_frames[cell_id]
    end
  end

  def test_primal_and_cellspace_movement_applied_once_without_regenerating_points
    primal = Primal.new(Frame.new(0, 100, 0))
    model = Model.new(primal, { 'A' => Frame.new(0, 10, 0) })
    overlay = Overlay.allocate
    overlay.instance_variable_set(:@indoor_model, model)
    local_point = Point.new(1, 0, 5)

    initial = overlay.send(:overlay_cell_reference_points, [local_point], 'A').first
    assert_in_delta 111, initial.x, 1e-9

    model.cell_frames['A'] = Frame.new(0, 20, 0)
    moved = overlay.send(:overlay_cell_reference_points, [local_point], 'A').first
    assert_in_delta 121, moved.x, 1e-9

    primal.world = Frame.new(0, 150, 0)
    primal_moved = overlay.send(:overlay_cell_reference_points, [local_point], 'A').first
    assert_in_delta 171, primal_moved.x, 1e-9
    assert_in_delta 50, primal_moved.x - moved.x, 1e-9
  end

  def test_cellspace_rotation_transforms_owned_points_independently
    model = Model.new(
      Primal.new(Frame.new(0, 100, 0)),
      { 'A' => Frame.new(Math::PI / 2, 10, 0),
        'B' => Frame.new(0, 40, 0) }
    )
    overlay = Overlay.allocate
    overlay.instance_variable_set(:@indoor_model, model)
    source = Point.new(1, 0, 5)

    a = overlay.send(:overlay_cell_reference_points, [source], 'A').first
    b = overlay.send(:overlay_cell_reference_points, [source], 'B').first
    assert_in_delta 110, a.x, 1e-9
    assert_in_delta 1, a.y, 1e-9
    assert_in_delta 141, b.x, 1e-9
    assert_in_delta 0, b.y, 1e-9
    assert_equal [], overlay.send(:overlay_cell_reference_points, [source], 'missing')
  end
end
