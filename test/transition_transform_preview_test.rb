# frozen_string_literal: true

require 'minitest/autorun'

unless defined?(Sketchup::Overlay)
  module Sketchup
    class Overlay; end
  end
end

require_relative '../indoor3d/ui/overlays/space_overlay'
require_relative '../indoor3d/ui/overlays/dual_graph_space_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      unless const_defined?(:DualOverlayPreferences, false)
        module DualOverlayPreferences
          def self.state_radius_scale
            1.0
          end
        end
      end
    end
  end
end

class TransitionTransformPreviewTest < Minitest::Test
  Overlay = ULOL::Indoor3DGmlModeler::IndoorCore::DualGraphSpaceOverlay
  Transform = Struct.new(:value) do
    def to_a
      [value]
    end
  end

  class Group
    attr_accessor :transformation
    attr_reader :persistent_id

    def initialize(persistent_id, value)
      @persistent_id = persistent_id
      @transformation = Transform.new(value)
    end
  end

  Cell = Struct.new(:group) do
    def valid_sketchup_group
      group
    end
  end

  Selection = Struct.new(:entities) do
    def each(&block)
      entities.each(&block)
    end
  end

  SketchupModel = Struct.new(:selection)
  IndoorModel = Struct.new(:model, :primal_group, :cell_spaces)

  class Builder
    attr_reader :invalidations

    def initialize
      @invalidations = 0
    end

    def invalidate
      @invalidations += 1
    end
  end

  class DrawCounter
    attr_reader :draws

    def initialize
      @draws = 0
    end

    def draw(*)
      @draws += 1
    end

    def draw_partitions(*)
      @draws += 1
    end

    def draw_edges(*)
      @draws += 1
    end
  end

  View = Struct.new(:line_width)

  def setup
    @primal = Group.new(10, 100)
    @cell_group = Group.new(20, 10)
    @selection = Selection.new([@cell_group])
    @builder = Builder.new
    indoor_model = IndoorModel.new(
      SketchupModel.new(@selection),
      @primal,
      [Cell.new(@cell_group)]
    )
    @overlay = Overlay.allocate
    @overlay.instance_variable_set(:@indoor_model, indoor_model)
    @overlay.instance_variable_set(:@transition_curve_builder, @builder)
    @overlay.instance_variable_set(:@transition_transform_keys, nil)
    @overlay.instance_variable_set(:@transition_transform_preview_active, false)
  end

  def test_selected_cell_transform_hides_until_transaction_finishes
    refute @overlay.send(:update_transition_transform_preview)

    @cell_group.transformation = Transform.new(15)
    assert @overlay.send(:update_transition_transform_preview)
    assert @overlay.send(:update_transition_transform_preview)
    assert_equal 0, @builder.invalidations

    assert @overlay.finish_transition_transform_preview
    assert_equal 1, @builder.invalidations
    refute @overlay.send(:update_transition_transform_preview)
  end

  def test_finish_detects_transform_change_even_without_intermediate_draw
    refute @overlay.send(:update_transition_transform_preview)
    @cell_group.transformation = Transform.new(15)

    assert @overlay.finish_transition_transform_preview
    assert_equal 1, @builder.invalidations
  end

  def test_selection_change_without_transform_does_not_start_preview
    refute @overlay.send(:update_transition_transform_preview)
    @selection.entities = [@primal]

    refute @overlay.send(:update_transition_transform_preview)
    refute @overlay.finish_transition_transform_preview
    assert_equal 0, @builder.invalidations
  end

  def test_draw_skips_transition_renderer_until_transform_finishes
    transition_renderer = DrawCounter.new
    @overlay.instance_variable_set(:@transition_renderer, transition_renderer)
    @overlay.instance_variable_set(:@reference_graph_debug_renderer, DrawCounter.new)
    @overlay.instance_variable_set(:@reference_point_debug_renderer, DrawCounter.new)
    @overlay.instance_variable_set(:@state_renderer, DrawCounter.new)
    @overlay.define_singleton_method(:draw_dual_overlay?) { true }
    @overlay.define_singleton_method(:validation_focus_active?) { false }
    view = View.new(1)

    @overlay.draw(view)
    assert_equal 1, transition_renderer.draws

    @cell_group.transformation = Transform.new(15)
    @overlay.draw(view)
    assert_equal 1, transition_renderer.draws

    @overlay.finish_transition_transform_preview
    @overlay.draw(view)
    assert_equal 2, transition_renderer.draws
  end
end
