# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Overlay
    attr_accessor :enabled

    def initialize(*); end

    def valid?
      true
    end
  end unless const_defined?(:Overlay, false)

  class Color
    def initialize(*); end
  end unless const_defined?(:Color, false)

  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

module Geom
  class BoundingBox; end unless const_defined?(:BoundingBox, false)

  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end
  end unless const_defined?(:Point3d, false)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/ui/overlays/space_overlay'
require_relative '../indoor3d/ui/overlays/builders/transition_curve_builder'
require_relative '../indoor3d/ui/overlays/renderers/state_overlay_renderer'
require_relative '../indoor3d/ui/overlays/renderers/transition_overlay_renderer'
require_relative '../indoor3d/ui/overlays/dual_graph_space_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DualGraphSpaceOverlayVisibilityTest < Minitest::Test
        def teardown
          Sketchup.test_active_model = nil
        end

        def test_edit_mode_does_not_force_dual_overlay_visible
          indoor_model = fake_indoor_model(editing: true, dual_overlay_visible: false)
          Sketchup.test_active_model = fake_model(active_path: [indoor_model.primal_group])
          overlay = DualGraphSpaceOverlay.new(indoor_model)

          assert_equal false, overlay.send(:draw_dual_overlay?)
        end

        def test_dual_overlay_visible_still_draws_in_edit_mode
          indoor_model = fake_indoor_model(editing: true, dual_overlay_visible: true)
          Sketchup.test_active_model = fake_model(active_path: [indoor_model.primal_group])
          overlay = DualGraphSpaceOverlay.new(indoor_model)

          assert_equal true, overlay.send(:draw_dual_overlay?)
        end

        private

        def fake_indoor_model(editing:, dual_overlay_visible:)
          primal_group = fake_primal_group
          Struct.new(:editing_value, :dual_overlay_value, :primal_group) do
            def editing?
              editing_value
            end

            def dual_overlay_visible?
              dual_overlay_value
            end

            def cell_space_geometry_editing?
              false
            end
          end.new(editing, dual_overlay_visible, primal_group)
        end

        def fake_primal_group
          Class.new do
            def valid?
              true
            end
          end.new
        end

        def fake_model(active_path:)
          Struct.new(:active_path).new(active_path)
        end
      end
    end
  end
end
