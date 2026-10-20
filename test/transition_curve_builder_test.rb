# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/ui/overlays/builders/transition_curve_builder'

class TransitionCurveBuilderTest < Minitest::Test
  Builder = ULOL::Indoor3DGmlModeler::IndoorCore::TransitionCurveBuilder
  Point = Struct.new(:x, :y, :z)
  Transition = Struct.new(:id, :state1_point, :state2_point, :selected_waypoint,
                          :cell1_id, :cell2_id, :state1, :state2)

  class FakeModel
    attr_accessor :transitions, :curve, :revisions

    def initialize(transition)
      @transitions = [transition]
      @curve = nil
      @revisions = {}
    end

    def reference_transition_curve(_first_cell_id, _second_cell_id, _waypoint)
      @curve
    end

    def reference_graph_route_snapshot_key_for(cell_id)
      @revisions[cell_id]
    end

    def dual_overlay_transition_visible?(_transition)
      true
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
  end

  def point(x)
    Point.new(x.to_f, 0.0, 0.0)
  end

  def setup
    @transition = Transition.new('T', point(0), point(4), point(2), 'A', 'B')
    @model = FakeModel.new(@transition)
    @builder = Builder.new(indoor_model: @model, transform_context: FakeTransform.new)
  end

  def xs(points)
    points.map(&:x)
  end

  def test_ref_graph_waypoint_paths_render_only_straight_gl_lines
    @model.curve = [point(0), point(1), point(2), point(3), point(4)]
    groups = @builder.transition_curve_segments(@transition)

    assert_equal [0.0, 1.0, 1.0, 2.0, 2.0, 3.0, 3.0, 4.0],
                 xs(groups[:default])
    assert_empty groups[:first]
    assert_empty groups[:second]
  end

  def test_missing_native_curve_fails_closed
    assert_empty @builder.transition_curve_segments(@transition)[:default]
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
                 xs(@builder.transition_curve_segments(@transition)[:default])
  end

  def test_exact_state_endpoints_are_preserved_when_graph_state_is_different
    @model.curve = [point(0.25), point(1), point(2), point(3), point(3.75)]
    assert_equal [0.0, 0.25, 0.25, 1.0, 1.0, 2.0, 2.0, 3.0,
                  3.0, 3.75, 3.75, 4.0],
                 xs(@builder.transition_curve_segments(@transition)[:default])
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
end
