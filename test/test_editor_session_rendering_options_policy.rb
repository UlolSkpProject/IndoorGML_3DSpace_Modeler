# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :active_model
  end
end

require_relative '../indoor3d/infrastructure/scene/editor_session/validation_focus_controller'
require_relative '../indoor3d/infrastructure/scene/editor_session/edit_active_path_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionRenderingOptionsPolicyTest < Minitest::Test
        def teardown
          Sketchup.active_model = nil
        end

        def test_row_selection_and_group_editing_apply_distinct_fix_mode_options
          primal = Object.new
          group = Object.new
          model = FakeModel.new([primal])
          Sketchup.active_model = model
          controller = EditorSession::ValidationFocusController.new

          controller.capture_and_apply_rendering_options(model, 1)
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1')

          assert_equal true, model.rendering_options['InactiveHidden']
          assert_equal false, model.rendering_options['ModelTransparency']

          model.active_path = [primal, group]
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1')

          assert_equal false, model.rendering_options['InactiveHidden']
          assert_equal true, model.rendering_options['ModelTransparency']

          model.active_path = [primal]
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1')

          assert_equal true, model.rendering_options['InactiveHidden']
          assert_equal false, model.rendering_options['ModelTransparency']
        end

        def test_fix_mode_rendering_options_restore_original_values
          model = FakeModel.new([Object.new])
          Sketchup.active_model = model
          controller = EditorSession::ValidationFocusController.new

          controller.capture_and_apply_rendering_options(model, 1)
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1')
          controller.restore_rendering_options(model)

          assert_equal false, model.rendering_options['InactiveHidden']
          assert_equal true, model.rendering_options['ModelTransparency']
          assert_equal 5, model.rendering_options['RenderMode']
          assert_equal true, model.rendering_options['Texture']
        end

        class FakeView
          def invalidate; end
        end

        class FakeModel
          attr_accessor :active_path
          attr_reader :rendering_options, :active_view

          def initialize(active_path)
            @active_path = active_path
            @rendering_options = {
              'InactiveHidden' => false,
              'ModelTransparency' => true,
              'RenderMode' => 5,
              'Texture' => true
            }
            @active_view = FakeView.new
          end
        end
      end
    end
  end
end
