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

        def test_focus_cell_space_matches_runtime_id_that_already_has_cell_prefix
          controller = EditorSession::ValidationFocusController.new
          focused = fake_cell_space(id: 'cell_A')

          assert_equal true, controller.begin(['cell_A'])

          assert_equal true, controller.focus_cell_space?(focused)
          assert_equal true, controller.begin(['cell_cell_A'])
          assert_equal true, controller.focus_cell_space?(focused)
        end

        def test_highlight_accepts_solid_cell_ref_alias
          controller = EditorSession::ValidationFocusController.new
          focused = fake_cell_space(id: 'b67d90rs')
          other = fake_cell_space(id: 'other')
          controller.begin(['cell_b67d90rs', 'cell_other'])

          controller.set_highlight(['solid_cell_b67d90rs'], '203')

          assert_equal true, controller.visible_cell_space?(focused)
          assert_equal false, controller.visible_cell_space?(other)
          assert_equal [focused], controller.highlight_cell_spaces([focused, other])
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

        def test_highlight_row_cell_updates_rebuild_highlight_and_base_focus
          controller = EditorSession::ValidationFocusController.new
          cell_a = fake_cell_space(id: 'A')
          cell_b = fake_cell_space(id: 'B')
          cell_c = fake_cell_space(id: 'C')
          controller.begin(%w[cell_A cell_B])
          controller.set_focus_rows([
                                      { id: 'row-1', cells: %w[A B], focus_ids: %w[cell_A cell_B], code: '701' },
                                      { id: 'row-2', cells: %w[C], focus_ids: %w[cell_C], code: '701' }
                                    ])
          controller.set_highlight(%w[cell_A cell_B], '701', row_id: 'row-1', row_cells: %w[A B])

          removed = controller.remove_highlight_cell('A')

          assert_equal 'row-1', removed[:row_id]
          assert_equal ['B'], removed[:cells]
          assert_equal 'cell_B', removed[:label]
          assert_equal false, controller.visible_cell_space?(cell_a)
          assert_equal true, controller.visible_cell_space?(cell_b)

          added = controller.add_highlight_cell('C')

          assert_equal %w[B C], added[:cells]
          assert_equal 'cell_B and cell_C', added[:label]
          assert_equal true, controller.visible_cell_space?(cell_c)
          assert_equal %w[B C], controller.focus_row('row-1')[:cells]

          row_snapshot = controller.focus_row('row-1')
          row_snapshot[:cells] << 'external-change'
          refute_includes controller.focus_row('row-1')[:cells], 'external-change'

          removed_from_rows = controller.remove_cell('C')

          assert_equal %w[row-1 row-2], removed_from_rows.map { |payload| payload[:row_id] }
          assert_equal ['B'], removed_from_rows.first[:cells]
          assert_equal [], removed_from_rows.last[:cells]
          assert_equal false, controller.visible_cell_space?(cell_c)

          controller.set_highlight([], '')

          assert_equal false, controller.visible_cell_space?(cell_a)
          assert_equal true, controller.visible_cell_space?(cell_b)
          assert_equal false, controller.visible_cell_space?(cell_c)
        end

        def test_highlighted_row_can_replace_its_last_cell_without_losing_row_selection
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{ id: 'row-1', cells: ['A'], focus_ids: ['cell_A'], code: '203' }])
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])

          removed = controller.remove_cell('A')
          assert controller.active?
          added = controller.add_highlight_cell('cell_B')

          assert_equal 'row-1', controller.highlight_row_id
          assert_equal [], removed.first[:cells]
          assert_equal ['B'], controller.highlighted_row_cells
          assert_equal %w[B cell_B], controller.highlighted_row_focus_ids
          assert_equal ['B'], added[:cells]
          assert_equal true, controller.highlighted_row_include_cell?('B')
          assert_equal true, controller.highlighted_row_include_cell?('cell_B')
        end

        def test_snapshot_restore_recovers_focus_rows_and_highlight
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{
                                      id: 'row-1',
                                      cells: ['A'],
                                      focus_ids: ['cell_A'],
                                      code: '203',
                                      geometry_refs: {
                                        faces: [{ cell_id: 'A', face_index: 11 }]
                                      }
                                    }])
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])
          snapshot = controller.snapshot

          controller.remove_cell('A')
          controller.add_highlight_cell('B')
          controller.restore!(snapshot)

          assert_equal ['A'], controller.highlighted_row_cells
          assert_equal ['cell_A'], controller.highlighted_row_focus_ids
          assert_equal 'row-1', controller.highlight_row_id
          assert_equal [{ cell_id: 'A', face_index: 11 }],
                       controller.focus_row('row-1').dig(:geometry_refs, :faces)
        end

        def test_reconcile_cells_only_removes_stale_refs_without_guessing_new_cells
          controller = EditorSession::ValidationFocusController.new
          controller.begin(%w[cell_A cell_B])
          controller.set_focus_rows([
                                      { id: 'row-1', cells: %w[A B], focus_ids: %w[cell_A cell_B], code: '203' },
                                      { id: 'row-2', cells: %w[B C], focus_ids: %w[cell_B cell_C], code: '204' }
                                    ])
          controller.set_highlight(%w[cell_A cell_B], '203', row_id: 'row-1', row_cells: %w[A B])

          payloads = controller.reconcile_cells(%w[B D])

          assert_equal %w[row-1 row-2], payloads.map { |payload| payload[:row_id] }
          assert_equal ['B'], controller.focus_row('row-1')[:cells]
          assert_equal ['B'], controller.focus_row('row-2')[:cells]
          refute_includes controller.focus_row('row-1')[:cells], 'D'
          assert_equal ['B'], controller.highlighted_row_cells
        end

        def test_rendering_options_are_captured_and_restored_for_multi_cell_focus
          options = {
            'HideRestOfModel' => true,
            'ROPDrawHiddenObjects' => true,
            'ROPDrawHiddenGeometry' => true,
            'DrawHidden' => true
          }
          view = fake_view
          model = Struct.new(:rendering_options, :active_view).new(options, view)
          controller = EditorSession::ValidationFocusController.new

          controller.capture_and_apply_rendering_options(model, 2)
          assert_equal false, options['HideRestOfModel']
          assert_equal false, options['ROPDrawHiddenObjects']
          assert_equal false, options['ROPDrawHiddenGeometry']
          assert_equal false, options['DrawHidden']
          assert_equal true, view.invalidated

          view.invalidated = false
          controller.restore_rendering_options(model)
          assert_equal true, options['HideRestOfModel']
          assert_equal true, options['ROPDrawHiddenObjects']
          assert_equal true, options['ROPDrawHiddenGeometry']
          assert_equal true, options['DrawHidden']
          assert_equal true, view.invalidated
        end

        def test_validation_focus_disables_hidden_and_hide_rest_options_for_single_cell_focus
          options = {
            'HideRestOfModel' => true,
            'ROPDrawHiddenObjects' => true,
            'ROPDrawHiddenGeometry' => true
          }
          view = fake_view
          model = Struct.new(:rendering_options, :active_view).new(options, view)
          controller = EditorSession::ValidationFocusController.new

          controller.capture_and_apply_rendering_options(model, 1)

          assert_equal false, options['HideRestOfModel']
          assert_equal false, options['ROPDrawHiddenObjects']
          assert_equal false, options['ROPDrawHiddenGeometry']
          assert_equal true, view.invalidated

          controller.restore_rendering_options(model)
          assert_equal true, options['HideRestOfModel']
          assert_equal true, options['ROPDrawHiddenObjects']
          assert_equal true, options['ROPDrawHiddenGeometry']
        end

        def test_edit_mode_rendering_options_disable_hidden_options_only
          options = {
            'HideRestOfModel' => true,
            'ROPDrawHiddenObjects' => true,
            'ROPDrawHiddenGeometry' => true
          }
          view = fake_view
          model = Struct.new(:rendering_options, :active_view).new(options, view)
          controller = EditorSession::ValidationFocusController.new

          controller.capture_and_apply_hidden_rendering_options(model)

          assert_equal true, options['HideRestOfModel']
          assert_equal false, options['ROPDrawHiddenObjects']
          assert_equal false, options['ROPDrawHiddenGeometry']
          assert_equal true, view.invalidated

          controller.restore_rendering_options(model)
          assert_equal true, options['HideRestOfModel']
          assert_equal true, options['ROPDrawHiddenObjects']
          assert_equal true, options['ROPDrawHiddenGeometry']
        end

        def test_missing_rendering_option_keys_are_ignored
          options = { 'HideRestOfModel' => true }
          view = fake_view
          model = Struct.new(:rendering_options, :active_view).new(options, view)
          controller = EditorSession::ValidationFocusController.new

          controller.capture_and_apply_rendering_options(model, 1)
          assert_equal false, options['HideRestOfModel']
          assert_equal true, view.invalidated

          controller.restore_rendering_options(model)

          assert_equal true, options['HideRestOfModel']
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
