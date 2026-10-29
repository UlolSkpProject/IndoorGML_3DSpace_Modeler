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
    assert_equal [102, 104, 203, 303, 307, 701], Service::SUPPORTED_CODES
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

  def test_701_auto_fix_uses_one_point_five_millimeter_thickness_limit
    expected_inches = 1.5 / 25.4

    assert_in_delta expected_inches, @service.send(:overlap_max_thickness_inches), 1.0e-12
  end

  def test_701_modification_priority_prefers_window_then_door
    window = overlap_target('Window')
    door = overlap_target('Door')

    selected = @service.send(:modification_targets, [door, window])

    assert_equal 1, selected.length
    assert_equal window[:cell_space], selected.first[:cell_space]
    assert_equal 1, selected.first[:pair_index]
  end

  def test_701_modification_priority_order
    categories = %w[Stair Room Elevator Door Window]
    ranks = categories.map do |category|
      @service.send(:overlap_modification_rank, overlap_target(category)[:cell_space])
    end

    assert_equal [4, 3, 2, 1, 0], ranks
  end

  def test_701_thickness_limit_includes_one_point_five_millimeters_and_rejects_larger_overlap
    tolerance = @service.send(:overlap_max_thickness_inches)

    assert @service.send(
      :overlap_candidate_within_limit?,
      { penetration_depth: 1.5 / 25.4 },
      tolerance
    )
    refute @service.send(
      :overlap_candidate_within_limit?,
      { penetration_depth: 1.501 / 25.4 },
      tolerance
    )
  end

  def test_701_multiple_face_candidates_selects_safe_plan_with_smallest_move
    tolerance = @service.send(:overlap_max_thickness_inches)
    targets = [overlap_target('Room'), overlap_target('Window')]
    target = targets.last.merge(pair_index: 1)
    candidates = [
      { penetration_depth: 0.16 / 25.4, overlap_area: 20.0, move: 0.29 / 25.4 },
      { penetration_depth: 0.11 / 25.4, overlap_area: 10.0, move: 0.21 / 25.4 }
    ]
    analysis = { adjacency_candidates: candidates }
    @service.define_singleton_method(:overlap_projection_plan_for_candidate) do |selected, _targets, candidate, _tolerance|
      {
        target: selected,
        target_index: selected[:pair_index],
        max_displacement: candidate[:move],
        penetration_depth: candidate[:penetration_depth],
        overlap_area: candidate[:overlap_area]
      }
    end

    plan = @service.send(
      :overlap_projection_plan_for_target,
      target,
      targets,
      analysis,
      tolerance
    )

    assert_in_delta 0.21 / 25.4, plan[:max_displacement], 1.0e-12
    assert_in_delta 0.11 / 25.4, plan[:penetration_depth], 1.0e-12
  end

  def test_701_accepts_reproduced_overlap_hidden_by_auto_fix_tolerance
    intersection = {
      status: :not_reproduced,
      reason: 'REPRODUCED_INTERSECTION_WITHIN_OVERLAP_TOLERANCE',
      volume: 0.0,
      raw_reproduced_volume: 8.928
    }

    assert @service.send(:repairable_overlap_intersection?, intersection)
  end

  def test_701_rejects_boundary_contact_without_positive_overlap_volume
    intersection = {
      status: :not_reproduced,
      reason: 'BOUNDARY_CONTACT_ONLY',
      volume: 0.0,
      raw_reproduced_volume: 8.928
    }

    refute @service.send(:repairable_overlap_intersection?, intersection)
  end

  def test_701_same_category_keeps_both_candidates_for_minimum_move_selection
    first = overlap_target('Room')
    second = overlap_target('Room')

    selected = @service.send(:modification_targets, [first, second])

    assert_equal [0, 1], selected.map { |target| target[:pair_index] }
  end

  def test_701_same_category_selects_projection_with_smaller_maximum_move
    first = overlap_target('Room', 'first')
    second = overlap_target('Room', 'second')
    analysis = {
      status: :ok,
      intersection: { status: :reproduced, volume: 1.0, component_count: 1 },
      adjacency_candidates: []
    }
    rechecker = Struct.new(:analysis) do
      def pair_analysis(_first, _second)
        analysis
      end
    end.new(analysis)
    @service.define_singleton_method(:overlap_rechecker) { |_tolerance| rechecker }
    @service.define_singleton_method(:overlap_projection_plan_for_target) do |target, _targets, _analysis, _tolerance|
      displacement = target[:pair_index].zero? ? 0.02 : 0.01
      { target: target, target_index: target[:pair_index], max_displacement: displacement }
    end

    plan = @service.send(:overlap_projection_plan, [first, second])

    assert_equal second[:cell_space], plan[:target][:cell_space]
  end

  def test_701_rejects_multiple_intersection_components
    targets = [overlap_target('Window', 'first'), overlap_target('Room', 'second')]
    analysis = {
      status: :ok,
      intersection: { status: :reproduced, volume: 1.0, component_count: 2 },
      adjacency_candidates: []
    }
    rechecker = Struct.new(:analysis) do
      def pair_analysis(_first, _second)
        analysis
      end
    end.new(analysis)
    @service.define_singleton_method(:overlap_rechecker) { |_tolerance| rechecker }

    assert_nil @service.send(:overlap_projection_plan, targets)
  end

  def test_701_unsupported_category_requires_manual_fix
    assert_empty @service.send(
      :modification_targets,
      [overlap_target('ExteriorDoor'), overlap_target('Unknown')]
    )
  end

  def test_unsupported_error_code_is_reported_without_geometry_access
    service = Service.new(indoor_model: nil, report: {})

    result = service.attempt(code: '201', row_id: 'validation-error-row-0')

    assert_equal 0, result.attempted
    assert_equal 0, result.fixed
    assert_equal 1, result.skipped
    assert_match(/지원하지 않습니다/, result.messages.first)
  end

  def test_blank_row_id_selects_every_row_for_supported_code
    indoor_model = Struct.new(:model, :states, :transitions).new(nil, [], [])
    service = Service.new(indoor_model: indoor_model, report: report_with_two_code_rows(203))

    rows = service.send(:selected_rows, 203, '')

    assert_equal 2, rows.length
    assert_equal %w[validation-error-row-0 validation-error-row-1], rows.map { |row| row[:id] }
  end

  def test_unsupported_bulk_attempt_counts_every_code_row_as_failed_candidate
    indoor_model = Struct.new(:model, :states, :transitions).new(nil, [], [])
    service = Service.new(indoor_model: indoor_model, report: report_with_two_code_rows(405))

    result = service.attempt(code: '405', row_id: '')

    assert_equal 0, result.fixed
    assert_equal 2, result.skipped
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

  def overlap_target(category, id = category.downcase)
    cell_space = Struct.new(:category_code, :id).new(category, id)
    { cell_space: cell_space, group: Object.new }
  end

  def report_with_two_code_rows(code)
    {
      'features' => [
        {
          'id' => 'IF_001',
          'errors' => [],
          'primitives' => [
            {
              'id' => 'solid_cell_alpha',
              'errors' => [
                { 'code' => code, 'description' => 'TEST_ERROR', 'id' => 'polygon_0_cell_alpha' }
              ]
            },
            {
              'id' => 'solid_cell_beta',
              'errors' => [
                { 'code' => code, 'description' => 'TEST_ERROR', 'id' => 'polygon_0_cell_beta' }
              ]
            }
          ]
        }
      ]
    }
  end
end
