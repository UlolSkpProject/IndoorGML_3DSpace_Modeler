# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/ui/overlays/builders/transition_curve_builder'

class TransitionCurveBuilderTest < Minitest::Test
  Builder = ULOL::Indoor3DGmlModeler::IndoorCore::TransitionCurveBuilder
  Point = Struct.new(:x, :y, :z)
  Transition = Struct.new(:id, :state1_point, :state2_point, :selected_waypoint,
                          :cell1_id, :cell2_id, :state1, :state2,
                          :selected_waypoint_normal1, :selected_waypoint_normal2)

  class FakeModel
    attr_accessor :transitions, :curve, :curves, :revisions, :state_visibility
    attr_reader :route_snapshot_calls, :reference_curve_calls

    def initialize(transition)
      @transitions = [transition]
      @curve = nil
      @curves = {}
      @revisions = {}
      @state_visibility = {}
      @route_snapshot_calls = []
      @reference_curve_calls = []
    end

    def reference_transition_curve(first_cell_id, second_cell_id, _waypoint)
      @reference_curve_calls << [first_cell_id, second_cell_id]
      @curves.fetch([first_cell_id, second_cell_id], @curve)
    end

    def reference_graph_route_snapshot_key_for(cell_id)
      @route_snapshot_calls << cell_id
      @revisions[cell_id]
    end

    def dual_overlay_transition_visible?(_transition)
      true
    end

    def dual_overlay_state_visible?(state)
      @state_visibility.fetch(state, true)
    end
  end

  class FakeTransform
    def overlay_render_point(point)
      point
    end

    def overlay_render_context_cache_key
      [:identity]
    end

    def overlay_render_context_snapshot
      { cache_key: [:identity] }
    end

    def overlay_render_point_from_snapshot(point, _snapshot)
      point
    end

    def overlay_render_vector_from_snapshot(vector, _snapshot)
      vector
    end
  end

  class OffsetTransform < FakeTransform
    def overlay_render_context_cache_key
      [:offset, 100]
    end

    def overlay_render_context_snapshot
      { cache_key: overlay_render_context_cache_key }
    end

    def overlay_render_point_from_snapshot(point, _snapshot)
      Point.new(point.x + 100.0, point.y, point.z)
    end
  end

  class MutableTransform < FakeTransform
    attr_accessor :offset

    def initialize(offset)
      @offset = offset
    end

    def overlay_render_context_cache_key
      [:offset, offset]
    end

    def overlay_render_context_snapshot
      { cache_key: overlay_render_context_cache_key }
    end

    def overlay_render_point_from_snapshot(point, _snapshot)
      Point.new(point.x + offset, point.y, point.z)
    end
  end

  def point(x)
    Point.new(x.to_f, 0.0, 0.0)
  end

  def point3(x, y, z = 0)
    Point.new(x.to_f, y.to_f, z.to_f)
  end

  def setup
    @transition = Transition.new('T', point(0), point(4), point(2), 'A', 'B', :state1, :state2)
    @model = FakeModel.new(@transition)
    @builder = Builder.new(indoor_model: @model, transform_context: FakeTransform.new)
  end

  def xs(points)
    points.map(&:x)
  end

  def segment_points(groups)
    groups.values_at(:default, :first, :second).flatten
  end

  def test_collinear_ref_graph_waypoint_paths_remain_straight_gl_lines
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    groups = @builder.transition_curve_segments(@transition)

    assert_empty groups[:default]
    assert_equal [0.0, 1.0, 1.0, 2.0], xs(groups[:first])
    assert_equal [2.0, 3.0, 3.0, 4.0], xs(groups[:second])
  end

  def test_curve_is_built_root_local_before_segments_are_rendered
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    builder = Builder.new(indoor_model: @model, transform_context: OffsetTransform.new)

    assert_equal [0.0, 1.0, 2.0, 3.0, 4.0], xs(builder.transition_curve_input(@transition)[:points])
    assert_equal [100.0, 101.0, 101.0, 102.0, 102.0, 103.0, 103.0, 104.0],
                 xs(builder.transition_line_points)
  end

  def test_direction_change_is_rounded_with_local_quadratic_bezier
    @transition.state2_point = point3(2, 1)
    @transition.selected_waypoint = point3(1, 1)
    @model.curve = [point3(0, 0), point3(1, 0), point3(1, 1)]

    input = @builder.transition_curve_input(@transition)
    segments = segment_points(@builder.transition_curve_segments_from_input(@transition, input))
    coordinates = segments.map { |value| [value.x, value.y, value.z] }

    assert_operator segments.length, :>, 6
    assert_equal [0.0, 0.0, 0.0], coordinates.first
    assert_equal [2.0, 1.0, 0.0], coordinates.last
    refute_includes coordinates, [1.0, 0.0, 0.0]
    assert coordinates.all? { |x, y, _z| x.between?(0.0, 2.0) && y.between?(0.0, 1.0) }
  end

  def test_exact_waypoint_is_protected_from_corner_rounding
    @transition.state2_point = point3(2, 1)
    @transition.selected_waypoint = point3(1, 1)
    @model.curve = [point3(0, 0), point3(1, 0), point3(1, 1)]

    input = @builder.transition_curve_input(@transition)
    segments = segment_points(@builder.transition_curve_segments_from_input(@transition, input))
    coordinates = segments.map { |value| [value.x, value.y, value.z] }

    protected_index = input[:protected_indices].first
    assert_equal [1.0, 1.0, 0.0], input[:points][protected_index].to_a
    assert_includes coordinates, [1.0, 1.0, 0.0]
  end

  def test_only_waypoint_departure_uses_selected_face_normal
    @transition.state2_point = point3(2, 1)
    @transition.selected_waypoint = point3(1, 1)
    @transition.selected_waypoint_normal1 = point3(1, 1)
    @model.curve = [point3(0, 0), point3(1, 0), point3(1, 1)]

    input = @builder.transition_curve_input(@transition)
    segments = segment_points(@builder.transition_curve_segments_from_input(@transition, input))
    pairs = segments.each_slice(2).to_a
    waypoint = [1.0, 1.0, 0.0]
    departing = pairs.find do |first, second|
      [first.x, first.y, first.z] == waypoint && [second.x, second.y, second.z] != waypoint
    end

    refute_nil departing
    straight_end = departing.last
    assert_operator straight_end.x, :>, 1.0
    assert_operator straight_end.y, :>, 1.0
    expected_projection = 1.0 / Math.sqrt(2.0)
    expected_magnitude = expected_projection * Builder::WAYPOINT_NORMAL_PROJECTION_RATIO
    assert_in_delta expected_magnitude,
                    Math.sqrt(((straight_end.x - 1.0)**2) + ((straight_end.y - 1.0)**2)),
                    1.0e-9
    assert_in_delta straight_end.x - 1.0, straight_end.y - 1.0, 1.0e-9

    incoming = pairs.find { |_first, second| [second.x, second.y, second.z] == waypoint }
    refute_nil incoming
    assert_in_delta 1.0, incoming.first.x, 1.0e-9
  end

  def test_waypoint_departure_normal_is_part_of_render_fingerprint
    @transition.selected_waypoint_normal1 = point3(1, 0)
    @model.curve = [point(0), point(1), point(2), point(4)]
    first = @builder.transition_curve_input(@transition)
    first_key = @builder.send(:transition_render_fingerprint, first, [:identity])

    @transition.selected_waypoint_normal1 = point3(0, 1)
    second = @builder.transition_curve_input(@transition)
    second_key = @builder.send(:transition_render_fingerprint, second, [:identity])

    refute_equal first_key, second_key
  end

  def test_waypoint_normal_change_rebuilds_assembled_cache_without_explicit_invalidate
    @transition.state2_point = point3(2, 1)
    @transition.selected_waypoint = point3(1, 1)
    @transition.selected_waypoint_normal1 = point3(1, 0)
    @model.curve = [point3(0, 0), point3(1, 0), point3(1, 1)]
    first = @builder.transition_line_points

    @transition.selected_waypoint_normal1 = point3(1, 1)
    second = @builder.transition_line_points

    refute_equal second.map { |value| [value.x, value.y, value.z] },
                 first.map { |value| [value.x, value.y, value.z] }
  end

  def test_missing_native_curve_fails_closed
    assert_empty segment_points(@builder.transition_curve_segments(@transition))
  end

  def test_missing_waypoint_connects_exact_state_endpoints
    @transition.selected_waypoint = nil
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    assert_equal [0.0, 4.0],
                 xs(@builder.transition_curve_segments(@transition)[:default])
  end

  def test_consecutive_duplicate_points_are_removed
    @model.curve = [point(0), point(0), point(2), point(2), point(4)]
    assert_equal [0.0, 2.0, 2.0, 4.0],
                 xs(segment_points(@builder.transition_curve_segments(@transition)))
  end

  def test_exact_state_endpoints_are_preserved_when_graph_state_is_different
    @model.curve = [point(0.25), point(1), point(2), point(3), point(3.75)]
    assert_equal [0.0, 0.25, 0.25, 1.0, 1.0, 2.0, 2.0, 3.0,
                  3.0, 3.75, 3.75, 4.0],
                 xs(segment_points(@builder.transition_curve_segments(@transition)))
  end

  def test_only_first_state_storey_draws_through_waypoint
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    @model.state_visibility[:state2] = false

    assert_equal [0.0, 1.0, 1.0, 2.0], xs(@builder.transition_line_points)
  end

  def test_only_second_state_storey_draws_from_waypoint
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    @model.state_visibility[:state1] = false

    assert_equal [2.0, 3.0, 3.0, 4.0], xs(@builder.transition_line_points)
  end

  def test_no_visible_state_storey_draws_no_transition
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    @model.state_visibility[:state1] = false
    @model.state_visibility[:state2] = false

    assert_empty @builder.transition_line_points
  end

  def test_route_coordinates_change_transition_cache_fingerprint
    @model.curve = [point(0), point(1), point(2), point(4)]
    first_input = @builder.transition_curve_input(@transition)
    original_key = @builder.send(:transition_render_fingerprint, first_input, [:identity])

    @model.curve = [point(0), point(1.5), point(2), point(4)]
    second_input = @builder.transition_curve_input(@transition)
    changed_key = @builder.send(:transition_render_fingerprint, second_input, [:identity])

    refute_equal original_key, changed_key
  end

  def test_cellspace_transform_change_invalidates_cache_without_graph_revision_change
    @model.curve = [point(0), point(1), point(2), point(4)]
    @model.revisions['A'] = [7, [:local_to_root, 0]]
    before = @builder.transition_line_points

    # Revision 7 stays constant: moving the CellSpace must still rebuild.
    @model.curve = [point(0), point(1.5), point(2), point(4)]
    @model.revisions['A'] = [7, [:local_to_root, 12]]
    after = @builder.transition_line_points

    refute_equal xs(before), xs(after)
    assert_equal [0.0, 1.5, 1.5, 2.0, 2.0, 4.0], xs(after)
  end

  def test_route_change_rebuilds_assembled_cache_without_explicit_invalidate
    @model.curve = [point(0), point(1), point(2), point(4)]
    @model.revisions['A'] = [:first_graph]
    first = @builder.transition_line_points
    assert_equal [0.0, 1.0, 1.0, 2.0, 2.0, 4.0], xs(first)

    @model.curve = [point(0), point(1.5), point(2), point(4)]
    @model.revisions['A'] = [:next_graph]
    second = @builder.transition_line_points
    assert_equal [0.0, 1.5, 1.5, 2.0, 2.0, 4.0], xs(second)
    refute_equal xs(first), xs(second)
    assert_same second, @builder.transition_line_points
  end

  def test_excluded_cell_transition_is_neither_calculated_nor_rendered
    other = Transition.new('T2', point(10), point(14), nil, 'C', 'D', :state3, :state4)
    @model.transitions = [@transition, other]
    @model.curve = [point(0), point(1), point(2), point(4)]

    points = @builder.transition_line_points(excluded_cell_ids: ['A'])

    assert_equal [10.0, 14.0], xs(points)
    refute_includes @model.route_snapshot_calls, 'A'
    refute_includes @model.route_snapshot_calls, 'B'
    assert_empty @model.reference_curve_calls
  end

  def test_selected_transition_highlights_only_the_selected_visible_half
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]

    first = @builder.transition_line_batches(selected_cell_ids: { 'A' => true })[:highlight]
    second = @builder.transition_line_batches(selected_cell_ids: { 'B' => true })[:highlight]
    both = @builder.transition_line_batches(selected_cell_ids: { 'A' => true, 'B' => true })[:highlight]

    assert_equal [0.0, 1.0, 1.0, 2.0], xs(first)
    assert_equal [2.0, 3.0, 3.0, 4.0], xs(second)
    assert_equal xs(first) + xs(second), xs(both)
    assert_empty @builder.transition_line_batches(selected_cell_ids: {})[:highlight]
    assert_empty @builder.transition_line_batches(selected_cell_ids: { 'C' => true })[:highlight]
  end

  def test_selection_batches_partition_cached_segments_without_overdraw
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]

    batches = @builder.transition_line_batches(selected_cell_ids: { 'A' => true })

    assert_equal [2.0, 3.0, 3.0, 4.0], xs(batches[:normal])
    assert_equal [0.0, 1.0, 1.0, 2.0], xs(batches[:highlight])
  end

  def test_empty_and_complete_selection_alias_the_canonical_full_array
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    full = @builder.transition_line_points

    empty = @builder.transition_line_batches(selected_cell_ids: {})
    complete = @builder.transition_line_batches(selected_cell_ids: { 'A' => true, 'B' => true })

    assert_same full, empty[:normal]
    assert_empty empty[:highlight]
    assert_empty complete[:normal]
    assert_same full, complete[:highlight]
  end

  def test_unchanged_selection_reuses_partition_arrays_without_curve_rebuild
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    first = @builder.transition_line_batches(selected_cell_ids: { 'A' => true })
    curve_calls = @model.reference_curve_calls.length
    second = @builder.transition_line_batches(selected_cell_ids: { 'A' => true })

    assert_same first, second
    assert_same first[:normal], second[:normal]
    assert_same first[:highlight], second[:highlight]
    assert_equal curve_calls, @model.reference_curve_calls.length
  end

  def test_selected_transition_respects_visibility_and_topology_suppression
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    @model.state_visibility[:state1] = false

    assert_empty @builder.transition_line_batches(selected_cell_ids: { 'A' => true })[:highlight]
    assert_equal [2.0, 3.0, 3.0, 4.0],
                 xs(@builder.transition_line_batches(selected_cell_ids: { 'B' => true })[:highlight])
    assert_empty @builder.transition_line_batches(
      selected_cell_ids: { 'B' => true },
      excluded_cell_ids: ['A']
    )[:highlight]
  end

  def test_selected_transition_reuses_existing_curve_cache
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]

    assert_equal [0.0, 1.0, 1.0, 2.0, 2.0, 3.0, 3.0, 4.0],
                 xs(@builder.transition_line_points)
    calls_after_base = @model.reference_curve_calls.length
    assert_equal [0.0, 1.0, 1.0, 2.0],
                 xs(@builder.transition_line_batches(selected_cell_ids: { 'A' => true })[:highlight])
    assert_equal calls_after_base, @model.reference_curve_calls.length
  end

  def test_changing_excluded_cells_rebuilds_assembled_transition_list
    other = Transition.new('T2', point(10), point(14), nil, 'C', 'D', :state3, :state4)
    @transition.selected_waypoint = nil
    @model.transitions = [@transition, other]

    assert_equal [10.0, 14.0], xs(@builder.transition_line_points(excluded_cell_ids: ['A']))
    assert_equal [0.0, 4.0], xs(@builder.transition_line_points(excluded_cell_ids: ['C']))
    assert_equal [0.0, 4.0, 10.0, 14.0], xs(@builder.transition_line_points)
  end

  def test_invalidating_one_transition_replaces_only_its_segment_caches
    other = Transition.new('T2', point(10), point(14), point(12), 'C', 'D', :state3, :state4)
    @model.transitions = [@transition, other]
    @model.curves[['A', 'B']] = [point(0), point(1), point(2), point(4)]
    @model.curves[['C', 'D']] = [point(10), point(11), point(12), point(14)]
    @builder.transition_line_points
    roots_before = @builder.instance_variable_get(:@root_segments_by_transition_id).dup
    worlds_before = @builder.instance_variable_get(:@world_segments_by_transition_id).dup

    @builder.invalidate_transitions([@transition])
    @builder.transition_line_points
    roots_after = @builder.instance_variable_get(:@root_segments_by_transition_id)
    worlds_after = @builder.instance_variable_get(:@world_segments_by_transition_id)

    refute_same roots_before['T'], roots_after['T']
    refute_same worlds_before['T'], worlds_after['T']
    assert_same roots_before['T2'], roots_after['T2']
    assert_same worlds_before['T2'], worlds_after['T2']
  end

  def test_removing_transition_drops_its_segment_caches_before_reassembly
    @model.curve = [point(0), point(1), point(2), point(4)]
    @builder.transition_line_points
    assert @builder.instance_variable_get(:@root_segments_by_transition_id).key?('T')

    @model.transitions = []
    @builder.remove_transitions(['T'])

    assert_empty @builder.transition_line_points
    refute @builder.instance_variable_get(:@root_segments_by_transition_id).key?('T')
    refute @builder.instance_variable_get(:@world_segments_by_transition_id).key?('T')
  end

  def test_primal_transform_reprojects_world_segments_without_rebuilding_root_curve
    @model.curve = [point(0), point(1), point(2), point(4)]
    transform = MutableTransform.new(100)
    builder = Builder.new(indoor_model: @model, transform_context: transform)
    assert_equal [100.0, 101.0, 101.0, 102.0, 102.0, 104.0], xs(builder.transition_line_points)
    root_before = builder.instance_variable_get(:@root_segments_by_transition_id)['T']
    curve_calls = @model.reference_curve_calls.length

    transform.offset = 200
    builder.invalidate_world_transform
    assert_equal [200.0, 201.0, 201.0, 202.0, 202.0, 204.0], xs(builder.transition_line_points)

    assert_same root_before, builder.instance_variable_get(:@root_segments_by_transition_id)['T']
    assert_equal curve_calls, @model.reference_curve_calls.length
  end

  def test_visibility_invalidation_only_reassembles_cached_world_segments
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    @builder.transition_line_points
    roots_before = @builder.instance_variable_get(:@root_segments_by_transition_id).dup
    worlds_before = @builder.instance_variable_get(:@world_segments_by_transition_id).dup
    curve_calls = @model.reference_curve_calls.length

    @model.state_visibility[:state2] = false
    @builder.invalidate_visibility
    assert_equal [0.0, 1.0, 1.0, 2.0], xs(@builder.transition_line_points)

    assert_same roots_before['T'], @builder.instance_variable_get(:@root_segments_by_transition_id)['T']
    assert_same worlds_before['T'], @builder.instance_variable_get(:@world_segments_by_transition_id)['T']
    assert_equal curve_calls, @model.reference_curve_calls.length
  end

  def test_selection_invalidation_rebuilds_only_partition_batches
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    first = @builder.transition_line_batches(selected_cell_ids: { 'A' => true })
    full_before = @builder.transition_line_points
    curve_calls = @model.reference_curve_calls.length

    @builder.invalidate_selection
    second = @builder.transition_line_batches(selected_cell_ids: { 'A' => true })

    refute_same first, second
    assert_same full_before, @builder.transition_line_points
    assert_equal curve_calls, @model.reference_curve_calls.length
  end

  def test_full_cache_reset_rebuilds_root_segments
    @model.curve = [point(0), point(1), point(2), point(4)]
    @builder.transition_line_points
    root_before = @builder.instance_variable_get(:@root_segments_by_transition_id)['T']
    curve_calls = @model.reference_curve_calls.length

    @builder.clear_cache
    @builder.transition_line_points

    refute_same root_before, @builder.instance_variable_get(:@root_segments_by_transition_id)['T']
    assert_operator @model.reference_curve_calls.length, :>, curve_calls
  end
end
