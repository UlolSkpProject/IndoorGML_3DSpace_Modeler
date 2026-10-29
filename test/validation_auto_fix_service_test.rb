# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/validity/validation_auto_fix_service'

class ValidationAutoFixServiceTest < Minitest::Test
  Service = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::ValidationAutoFixService

  Point = Struct.new(:x, :y, :z) do
    def transform(_transformation)
      self
    end

    def distance(other)
      Math.sqrt(((x - other.x)**2) + ((y - other.y)**2) + ((z - other.z)**2))
    end

    def vector_to(other)
      Point.new(other.x - x, other.y - y, other.z - z)
    end
  end

  Vertex = Struct.new(:position, :edges, :faces)
  Loop = Struct.new(:vertices, :edges)
  Face = Struct.new(:loops)

  class Edge
    attr_reader :start, :end, :persistent_id

    def initialize(id, start_vertex, end_vertex)
      @persistent_id = id
      @start = start_vertex
      @end = end_vertex
      start_vertex.edges << self
      end_vertex.edges << self
    end

    def valid?
      true
    end
  end

  def setup
    @service = Service.allocate
  end

  def test_supported_codes_include_orientation_repairs
    assert_equal [102, 104, 203, 303, 307], Service::SUPPORTED_CODES
  end

  def test_degree_two_edge_plan_collapses_one_endpoint
    first = vertex(0.0, 0.0)
    second = vertex(0.0005, 0.0)
    edge = Edge.new(1, first, second)
    attach_extra_edge(2, first)
    attach_extra_edge(3, second)
    loop = Loop.new([first, second], [edge])

    plan = collapse_plan(edge, loop)

    assert_equal :degree_2_edge, plan[:kind]
    assert_equal 1, plan[:moves].length
  end

  def test_triangle_plan_collapses_sliver_edge_when_vertices_have_other_connections
    first = vertex(0.0, 0.0)
    second = vertex(0.0005, 0.0)
    third = vertex(1.0, 0.0)
    target = Edge.new(10, first, second)
    second_to_third = Edge.new(11, second, third)
    third_to_first = Edge.new(12, third, first)
    attach_extra_edge(13, first)
    attach_extra_edge(14, second)
    loop = Loop.new([first, second, third], [target, second_to_third, third_to_first])

    plan = collapse_plan(target, loop)

    assert_equal :sliver_triangle, plan[:kind]
    assert_equal 1, plan[:moves].length
  end

  def test_quad_plan_collapses_both_congruent_short_edges
    first = vertex(0.0, 0.0)
    second = vertex(0.0005, 0.0)
    third = vertex(0.0005, 1.0)
    fourth = vertex(0.0, 1.0)
    target = Edge.new(20, first, second)
    side1 = Edge.new(21, second, third)
    opposite = Edge.new(22, third, fourth)
    side2 = Edge.new(23, fourth, first)
    attach_extra_edge(24, first)
    attach_extra_edge(25, second)
    loop = Loop.new([first, second, third, fourth], [target, side1, opposite, side2])

    plan = collapse_plan(target, loop)

    assert_equal :sliver_quad, plan[:kind]
    assert_equal 2, plan[:moves].length
  end

  def test_quad_plan_rejects_non_short_opposite_edge
    first = vertex(0.0, 0.0)
    second = vertex(0.0005, 0.0)
    third = vertex(0.002, 1.0)
    fourth = vertex(0.0, 1.0)
    target = Edge.new(30, first, second)
    side1 = Edge.new(31, second, third)
    opposite = Edge.new(32, third, fourth)
    side2 = Edge.new(33, fourth, first)
    attach_extra_edge(34, first)
    attach_extra_edge(35, second)
    loop = Loop.new([first, second, third, fourth], [target, side1, opposite, side2])

    assert_nil collapse_plan(target, loop)
  end

  def test_duplicate_edge_detection_is_limited_to_repeated_loop_edge
    first = vertex(0.0, 0.0)
    second = vertex(1.0, 0.0)
    third = vertex(1.0, 1.0)
    repeated = Edge.new(40, first, second)
    other = Edge.new(41, second, third)
    face = Face.new([Loop.new([first, second, third, second], [repeated, other, other, repeated])])

    duplicates = @service.send(:duplicate_edges_for_face, face)

    assert_equal [repeated, other], duplicates
  end

  def test_203_accepts_vertex_when_every_adjacent_face_is_quadrilateral
    target = Struct.new(:vertices).new(Array.new(5))
    first_quad = Struct.new(:vertices).new(Array.new(4))
    second_quad = Struct.new(:vertices).new(Array.new(4))
    candidate = vertex(0.0, 0.0)
    candidate.faces.concat([target, first_quad, second_quad])

    assert @service.send(:adjacent_faces_all_quadrilateral?, candidate, target)
  end

  def test_203_rejects_vertex_when_an_adjacent_face_is_not_quadrilateral
    target = Struct.new(:vertices).new(Array.new(5))
    quad = Struct.new(:vertices).new(Array.new(4))
    triangle = Struct.new(:vertices).new(Array.new(3))
    candidate = vertex(0.0, 0.0)
    candidate.faces.concat([target, quad, triangle])

    refute @service.send(:adjacent_faces_all_quadrilateral?, candidate, target)
  end

  def test_203_auto_fix_uses_point_zero_one_millimeter_tolerance
    expected_inches = 0.01 / 25.4

    assert_in_delta expected_inches, @service.send(:planarity_tolerance_inches), 1.0e-12
  end

  def test_unsupported_error_code_is_reported_without_geometry_access
    service = Service.new(indoor_model: nil, report: {})

    result = service.attempt(code: '201', row_id: 'validation-error-row-0')

    assert_equal 0, result.attempted
    assert_equal 0, result.fixed
    assert_equal 1, result.skipped
    assert_match(/지원하지 않습니다/, result.messages.first)
  end

  private

  def vertex(x, y, z = 0.0)
    Vertex.new(Point.new(x, y, z), [], [])
  end

  def attach_extra_edge(id, source)
    Edge.new(id, source, vertex(id.to_f, id.to_f))
  end

  def collapse_plan(edge, loop)
    @service.send(
      :collapse_plan_for,
      { edge: edge, loop: loop, transform: Object.new },
      0.001
    )
  end
end
