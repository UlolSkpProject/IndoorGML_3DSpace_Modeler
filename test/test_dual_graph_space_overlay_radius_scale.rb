# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Overlay
    def initialize(*); end

    def valid?
      true
    end
  end unless const_defined?(:Overlay, false)

  class Color
    def initialize(*); end
  end unless const_defined?(:Color, false)

  class << self
    attr_accessor :test_active_model, :test_defaults
  end

  def self.active_model
    test_active_model
  end

  def self.read_default(section, key, fallback = nil)
    test_defaults.fetch([section, key], fallback)
  end

  def self.write_default(section, key, value)
    test_defaults[[section, key]] = value
  end
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

  class BoundingBox
    attr_reader :points

    def initialize
      @points = []
    end

    def add(*points)
      @points.concat(points)
    end
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      class State
        def self.display_radius
          1.0
        end
      end unless const_defined?(:State)
    end
  end
end

require_relative '../indoor3d/infrastructure/preferences/user_preferences'
require_relative '../indoor3d/infrastructure/preferences/dual_overlay_preferences'
require_relative '../indoor3d/ui/overlays/space_overlay'
require_relative '../indoor3d/ui/overlays/builders/transition_curve_builder'
require_relative '../indoor3d/ui/overlays/renderers/state_overlay_renderer'
require_relative '../indoor3d/ui/overlays/renderers/transition_overlay_renderer'
require_relative '../indoor3d/ui/overlays/dual_graph_space_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DualGraphSpaceOverlayRadiusScaleTest < Minitest::Test
        def setup
          Sketchup.test_active_model = fake_active_model
          Sketchup.test_defaults = {
            [UserPreferences::SECTION, DualOverlayPreferences::STATE_RADIUS_SCALE_KEY] => 1.75
          }
        end

        def teardown
          Sketchup.test_active_model = nil
        end

        def test_draw_passes_preference_scale_to_state_renderer
          indoor_model = fake_indoor_model(states: [])
          overlay = DualGraphSpaceOverlay.new(indoor_model)
          state_renderer = fake_state_renderer
          overlay.instance_variable_set(:@state_renderer, state_renderer)
          overlay.instance_variable_set(:@transition_renderer, fake_transition_renderer)

          overlay.draw(fake_view)

          assert_equal [1.75], state_renderer.scales
        end

        def test_get_extents_applies_preference_and_degree_scale_to_bounds
          state = fake_state(radius: 10.0, transitions: [fake_transition, fake_transition, fake_transition, fake_transition])
          indoor_model = fake_indoor_model(states: [state])
          overlay = DualGraphSpaceOverlay.new(indoor_model)

          bounds = overlay.getExtents

          assert_equal 2, bounds.points.length
          assert_in_delta(-21.137, bounds.points.first.x, 0.001)
          assert_in_delta(21.137, bounds.points.last.x, 0.001)
        end

        private

        def fake_state_renderer
          Class.new do
            attr_reader :scales

            def initialize
              @scales = []
            end

            def draw(_view, state_radius_scale:)
              @scales << state_radius_scale
            end
          end.new
        end

        def fake_transition_renderer
          Class.new do
            def draw(_view); end
          end.new
        end

        def fake_view
          Class.new do
            attr_accessor :line_width

            def respond_to?(name, include_private = false)
              name == :line_width= || super
            end
          end.new
        end

        def fake_active_model
          Struct.new(:active_path).new(nil)
        end

        def fake_indoor_model(states:)
          primal_group = fake_primal_group
          Struct.new(:states, :primal_group) do
            def transitions
              []
            end

            def dual_overlay_visible?
              true
            end

            def cell_space_geometry_editing?
              false
            end

            def validation_focus_active?
              false
            end

            def dual_overlay_state_visible?(_state)
              true
            end
          end.new(states, primal_group)
        end

        def fake_primal_group
          Class.new do
            def valid?
              true
            end
          end.new
        end

        def fake_state(radius:, transitions:)
          Struct.new(:radius, :transitions, :position) do
            def valid?
              true
            end

            def duality_cell
              nil
            end
          end.new(radius, transitions, Geom::Point3d.new(0, 0, 0))
        end

        def fake_transition
          Class.new do
            def valid?
              true
            end
          end.new
        end
      end
    end
  end
end
