# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Color
    def initialize(*); end
  end unless const_defined?(:Color, false)
end

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end unless const_defined?(:Point3d, false)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class State
        def self.display_radius
          1.0
        end
      end unless const_defined?(:State)
    end
  end
end

require_relative '../indoor3d/ui/overlays/renderers/state_overlay_renderer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class StateOverlayRendererTest < Minitest::Test
        def test_draws_all_visible_valid_states_in_one_call
          states = [
            drawable_state(position: Geom::Point3d.new(1, 0, 0)),
            drawable_state(position: Geom::Point3d.new(2, 0, 0)),
            drawable_state(
              position: Geom::Point3d.new(3, 0, 0),
              transitions: Array.new(4) { fake_transition(true) }
            ),
            drawable_state(position: Geom::Point3d.new(4, 0, 0), valid: false),
            drawable_state(position: Geom::Point3d.new(5, 0, 0), visible: false)
          ]
          view = recording_view
          renderer = renderer_for(states)

          renderer.draw(view)

          assert_equal 1, view.point_calls.length
          call = view.point_calls.first
          assert_equal states.first(3).map(&:position), call[:points]
          assert_equal 12, call[:size]
          assert_equal StateOverlayRenderer::STATE_POINT_STYLE, call[:style]
        end

        def test_repeated_draw_reuses_cached_points_without_recalculating_positions
          state = drawable_state(position: Geom::Point3d.new(1, 0, 0))
          context = drawing_transform_context
          view = recording_view
          renderer = renderer_for([state], transform_context: context)

          renderer.draw(view)
          first_bucket = view.point_calls.first[:points]
          view.point_calls.clear
          renderer.draw(view)

          assert_same first_bucket, view.point_calls.first[:points]
          assert_equal 1, context.render_point_calls
        end

        def test_scale_change_changes_draw_size_without_recalculating_positions
          state = drawable_state(position: Geom::Point3d.new(1, 0, 0))
          context = drawing_transform_context
          renderer = renderer_for([state], transform_context: context)

          first_view = recording_view
          second_view = recording_view
          renderer.draw(first_view, state_radius_scale: 1.0)
          renderer.draw(second_view, state_radius_scale: 2.0)

          assert_equal 1, context.render_point_calls
          assert_equal 12, first_view.point_calls.first[:size]
          assert_equal 24, second_view.point_calls.first[:size]
        end

        def test_clear_cache_recalculates_positions_on_next_draw
          state = drawable_state(position: Geom::Point3d.new(1, 0, 0))
          context = drawing_transform_context
          renderer = renderer_for([state], transform_context: context)

          renderer.draw(recording_view)
          renderer.clear_cache
          renderer.draw(recording_view)

          assert_equal 2, context.render_point_calls
        end

        def test_clear_cache_includes_state_registered_after_first_draw
          first_state = drawable_state(position: Geom::Point3d.new(1, 0, 0))
          states = [first_state]
          renderer = renderer_for(states)
          first_view = recording_view
          second_view = recording_view

          renderer.draw(first_view)
          second_state = drawable_state(position: Geom::Point3d.new(2, 0, 0))
          states << second_state
          renderer.clear_cache
          renderer.draw(second_view)

          assert_equal [first_state.position, second_state.position], second_view.point_calls.first[:points]
        end

        def test_point_size_applies_preference_and_clamps
          renderer = renderer_for([])

          assert_equal 12, renderer.overlay_state_point_size(state_radius_scale: 1.0)
          assert_equal 10, renderer.overlay_state_point_size(state_radius_scale: 0.1)
          assert_equal 24, renderer.overlay_state_point_size(state_radius_scale: 10.0)
        end

        def test_overlay_state_bounds_radius_applies_preference_scale_only
          renderer = renderer_for([])
          transitions = Array.new(4) { fake_transition(true) }
          state = fake_state(radius: 10.0, transitions: transitions)

          radius = renderer.overlay_state_bounds_radius(state, state_radius_scale: 1.5)

          assert_in_delta 15.0, radius, 0.001
        end

        private

        def renderer_for(states, transform_context: drawing_transform_context)
          StateOverlayRenderer.new(
            indoor_model: Struct.new(:states).new(states),
            transform_context: transform_context
          )
        end

        def recording_view
          Class.new do
            attr_reader :point_calls

            def initialize
              @point_calls = []
            end

            def draw_points(points, size, style, color)
              @point_calls << { points: points, size: size, style: style, color: color }
            end
          end.new
        end

        def drawing_transform_context
          Class.new do
            attr_reader :render_point_calls

            def initialize
              @render_point_calls = 0
            end

            def overlay_state_visible?(state)
              state.visible
            end

            def overlay_state_root_local_point(state)
              state.position
            end

            def overlay_render_point(point)
              @render_point_calls += 1
              point
            end
          end.new
        end

        def drawable_state(position:, transitions: [], valid: true, visible: true)
          Struct.new(:position, :radius, :transitions, :valid_value, :visible) do
            def valid?
              valid_value
            end
          end.new(position, 1.0, transitions, valid, visible)
        end

        def fake_state(radius:, transitions:)
          Struct.new(:radius, :transitions).new(radius, transitions)
        end

        def fake_transition(valid)
          Struct.new(:valid_value) do
            def valid?
              valid_value
            end
          end.new(valid)
        end
      end
    end
  end
end
