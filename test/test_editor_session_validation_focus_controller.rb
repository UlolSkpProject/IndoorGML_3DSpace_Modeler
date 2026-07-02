# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/editor_session/validation_focus_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionValidationFocusControllerTest < Minitest::Test
        def test_begin_and_focus_cell_space_match_gml_id
          controller = EditorSession::ValidationFocusController.new
          focused = fake_cell_space(id: 'A 1')
          other = fake_cell_space(id: 'B')

          assert_equal true, controller.begin(['cell_A_1'])

          assert_equal true, controller.active?
          assert_equal true, controller.focus_cell_space?(focused)
          assert_equal false, controller.focus_cell_space?(other)
        end

        def test_highlight_limits_visible_cell_space_when_present
          controller = EditorSession::ValidationFocusController.new
          focused = fake_cell_space(id: 'A')
          highlighted = fake_cell_space(id: 'B')
          hidden = fake_cell_space(id: 'C')
          controller.begin(%w[cell_A cell_B cell_C])

          assert_equal true, controller.visible_cell_space?(focused)

          controller.set_highlight(['cell_B'], '701')

          assert_equal false, controller.visible_cell_space?(focused)
          assert_equal true, controller.visible_cell_space?(highlighted)
          assert_equal false, controller.visible_cell_space?(hidden)
          assert_equal [highlighted], controller.highlight_cell_spaces([focused, highlighted, hidden])
          assert_equal '701', controller.highlight_code
        end

        def test_elements_returns_focused_cells_states_and_internal_transitions
          controller = EditorSession::ValidationFocusController.new
          cell_a = fake_cell_space(id: 'A')
          cell_b = fake_cell_space(id: 'B')
          cell_c = fake_cell_space(id: 'C')
          transition_inside = fake_transition(cell_a, cell_b)
          transition_outside = fake_transition(cell_a, cell_c)
          controller.begin(%w[cell_A cell_B])

          elements = controller.elements(
            cell_spaces: [cell_a, cell_b, cell_c],
            transitions: [transition_inside, transition_outside]
          )

          assert_equal [cell_a, cell_b], elements[:cell_spaces]
          assert_equal [cell_a.duality_state, cell_b.duality_state], elements[:states]
          assert_equal [transition_inside], elements[:transitions]
        end

        def test_visibility_snapshots_are_remembered_and_cleared
          controller = EditorSession::ValidationFocusController.new

          controller.remember_visibility_snapshot(10, :first)
          controller.remember_visibility_snapshot(10, :second)

          assert_equal true, controller.visibility_snapshot?(10)
          assert_equal :first, controller.visibility_snapshot(10)

          controller.clear_visibility_snapshots
          assert_equal false, controller.visibility_snapshot?(10)
        end

        def test_rendering_options_are_captured_and_restored_for_multi_cell_focus
          options = { 'HideRestOfModel' => true }
          view = fake_view
          model = Struct.new(:rendering_options, :active_view).new(options, view)
          controller = EditorSession::ValidationFocusController.new

          controller.capture_and_apply_rendering_options(model, 2)
          assert_equal false, options['HideRestOfModel']
          assert_equal true, view.invalidated

          view.invalidated = false
          controller.restore_rendering_options(model)
          assert_equal true, options['HideRestOfModel']
          assert_equal true, view.invalidated
        end

        private

        def fake_cell_space(id:)
          state_class = Struct.new(:duality_cell) do
            def valid?
              true
            end
          end
          cell_class = Struct.new(:id, :duality_state) do
            def valid?
              true
            end
          end
          cell = cell_class.new(id, nil)
          cell.duality_state = state_class.new(cell)
          cell
        end

        def fake_transition(cell1, cell2)
          Struct.new(:state1, :state2) do
            def valid?
              true
            end
          end.new(cell1.duality_state, cell2.duality_state)
        end

        def fake_view
          Class.new do
            attr_accessor :invalidated

            def initialize
              @invalidated = false
            end

            def invalidate
              @invalidated = true
            end
          end.new
        end
      end
    end
  end
end
