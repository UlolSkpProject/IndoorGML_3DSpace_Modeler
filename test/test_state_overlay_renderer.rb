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
        def test_overlay_state_radius_applies_model_radius_scale
          renderer = StateOverlayRenderer.new(indoor_model: fake_indoor_model, transform_context: fake_transform_context)
          state = fake_state(radius: 8.0, transitions: [])

          radius = renderer.overlay_state_radius(fake_view, Geom::Point3d.new(0, 0, 0), state, 1.5)

          assert_equal 12.0, radius
        end

        def test_overlay_state_radius_scales_min_pixel_clamp
          renderer = StateOverlayRenderer.new(indoor_model: fake_indoor_model, transform_context: fake_transform_context)
          state = fake_state(radius: 1.0, transitions: [])

          radius = renderer.overlay_state_radius(fake_view, Geom::Point3d.new(0, 0, 0), state, 2.0)

          assert_equal 10.0, radius
        end

        def test_overlay_state_radius_scales_max_pixel_clamp_without_hardcoded_multiplier
          renderer = StateOverlayRenderer.new(indoor_model: fake_indoor_model, transform_context: fake_transform_context)
          state = fake_state(radius: 100.0, transitions: [])

          radius = renderer.overlay_state_radius(fake_view, Geom::Point3d.new(0, 0, 0), state, 0.5)

          assert_equal 5.0, radius
        end

        def test_overlay_state_bounds_radius_applies_degree_and_preference_scale
          renderer = StateOverlayRenderer.new(indoor_model: fake_indoor_model, transform_context: fake_transform_context)
          transitions = [fake_transition(true), fake_transition(true), fake_transition(true), fake_transition(true)]
          state = fake_state(radius: 10.0, transitions: transitions)

          radius = renderer.overlay_state_bounds_radius(state, state_radius_scale: 1.5)

          assert_in_delta 18.117, radius, 0.001
        end

        private

        def fake_view
          Class.new do
            def pixels_to_model(pixels, _center)
              pixels
            end
          end.new
        end

        def fake_indoor_model
          Object.new
        end

        def fake_transform_context
          Object.new
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
