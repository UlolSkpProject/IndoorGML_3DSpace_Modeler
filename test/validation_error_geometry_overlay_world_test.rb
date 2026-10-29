# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Overlay
    attr_accessor :enabled

    def initialize(id, _name, **_options)
      @id = id
    end

    def overlay_id
      @id
    end

    def valid?
      true
    end
  end

  class Color
    def initialize(*values)
      @values = values
    end
  end

  class << self
    attr_accessor :active_model
  end
end unless defined?(Sketchup::Overlay)

module Geom
  Point3d = Struct.new(:x, :y, :z) unless const_defined?(:Point3d)

  class BoundingBox
    attr_reader :points

    def initialize
      @points = []
    end

    def add(point)
      @points << point
    end

    def min
      Point3d.new(*[0, 1, 2].map { |i| @points.map { |p| [p.x, p.y, p.z][i] }.min })
    end

    def max
      Point3d.new(*[0, 1, 2].map { |i| @points.map { |p| [p.x, p.y, p.z][i] }.max })
    end

    def empty?
      @points.empty?
    end
  end
end unless defined?(Geom::BoundingBox)

GL_TRIANGLES = 4 unless defined?(GL_TRIANGLES)
GL_LINES = 1 unless defined?(GL_LINES)

require_relative '../indoor3d/ui/overlays/space_overlay'
require_relative '../indoor3d/ui/overlays/validation_error_geometry_overlay'

class ValidationErrorGeometryOverlayWorldTest < Minitest::Test
  Overlay = ULOL::Indoor3DGmlModeler::IndoorCore::ValidationErrorGeometryOverlay
  Point = Geom::Point3d

  class Model
    attr_accessor :active_path, :edit_transform_calls

    def initialize
      @edit_transform_calls = 0
    end

    def edit_transform
      @edit_transform_calls += 1
      raise 'Overlay tried to reapply the ActivePath transformation'
    end
  end

  class Indoor
    attr_reader :primal_group

    def initialize
      @primal_group = Object.new
    end

    def validation_focus_active?
      true
    end
  end

  class View
    attr_accessor :drawing_color, :line_width, :line_stipple
    attr_reader :draws

    def initialize
      @draws = []
    end

    def draw(mode, points)
      @draws << [mode, points.dup]
    end
  end

  def setup
    @model = Model.new
    Sketchup.active_model = @model
    @indoor = Indoor.new
    @overlay = Overlay.new(@indoor)
    @view = View.new
  end

  def teardown
    Sketchup.active_model = nil
  end

  def point(x, y, z)
    Point.new(x, y, z)
  end

  def geometry
    # These coordinates are already transformed into world/model space by
    # ValidationErrorGeometryResolver. No edit_transform may be applied here.
    p0 = point(120, -40, 5)
    p1 = point(120, -30, 5)
    p2 = point(115, -30, 15)
    q0 = point(-220, 80, 0)
    q1 = point(-210, 80, 0)
    q2 = point(-210, 82, 20)
    {
      face_triangles: [[p0, p1, p2]],
      face_edges: [p0, p1, p1, p2],
      overlap_triangles: [[q0, q1, q2]],
      overlap_edges: [q0, q1]
    }
  end

  def test_overlay_id_and_original_color_contract_are_retained
    assert_equal 'ulol.indoor3dgml_modeler.validation_error_geometry_overlay', Overlay::OVERLAY_ID
    assert_equal 'IndoorGML Validation Error Geometry Overlay', Overlay::OVERLAY_NAME
  end

  def test_face_and_overlap_geometry_render_in_distinct_passes
    data = geometry
    @overlay.set_geometry(data)
    @overlay.draw(@view)

    assert_equal [GL_TRIANGLES, GL_LINES, GL_TRIANGLES, GL_LINES], @view.draws.map(&:first)
    assert_equal data[:face_triangles].flatten(1), @view.draws[0][1]
    assert_equal data[:face_edges], @view.draws[1][1]
    assert_equal data[:overlap_triangles].flatten(1), @view.draws[2][1]
    assert_equal data[:overlap_edges], @view.draws[3][1]
  end

  def test_world_extents_match_actual_draw_points
    data = geometry
    @overlay.set_geometry(data)
    bounds = @overlay.getExtents
    points = @view.draws
    @overlay.draw(@view)
    points = @view.draws.flat_map(&:last)
    assert_equal points.map(&:x).min, bounds.min.x
    assert_equal points.map(&:y).min, bounds.min.y
    assert_equal points.map(&:z).min, bounds.min.z
    assert_equal points.map(&:x).max, bounds.max.x
    assert_equal points.map(&:y).max, bounds.max.y
    assert_equal points.map(&:z).max, bounds.max.z
  end

  def test_active_path_does_not_retransform_world_geometry
    data = geometry
    @model.active_path = [@indoor.primal_group, Object.new]
    @overlay.set_geometry(data)
    @overlay.draw(@view)
    assert_equal data[:face_triangles].flatten(1), @view.draws.first.last
    assert_equal 0, @model.edit_transform_calls
    assert_equal 120, @overlay.getExtents.max.x
  end

  def test_nested_component_edit_path_does_not_double_transform_world_points
    @model.active_path = [@indoor.primal_group, Object.new, Object.new]
    world = geometry
    @overlay.set_geometry(world)
    @overlay.draw(@view)

    assert_equal world[:face_triangles].flatten(1), @view.draws.first.last
    assert_equal 0, @model.edit_transform_calls
    assert_equal(-220, @overlay.getExtents.min.x)
    assert_equal 120, @overlay.getExtents.max.x
  end

  def test_cleared_geometry_draws_nothing_and_extents_are_empty
    @overlay.set_geometry(geometry)
    @overlay.clear
    @overlay.draw(@view)
    assert_empty @view.draws
    assert @overlay.getExtents.empty?
  end

  def test_empty_geometry_has_no_marker_or_crosshair
    @overlay.set_geometry({
      face_triangles: [], face_edges: [],
      overlap_triangles: [], overlap_edges: []
    })
    @overlay.draw(@view)
    assert_empty @view.draws
    assert @overlay.getExtents.empty?
  end

  def test_face_only_and_overlap_only_do_not_mix_render_channels
    original = geometry
    @overlay.set_geometry(original.merge(overlap_triangles: [], overlap_edges: []))
    @overlay.draw(@view)
    assert_equal [GL_TRIANGLES, GL_LINES], @view.draws.map(&:first)

    @view.draws.clear
    @overlay.set_geometry(original.merge(face_triangles: [], face_edges: []))
    @overlay.draw(@view)
    assert_equal [GL_TRIANGLES, GL_LINES], @view.draws.map(&:first)
  end
end
