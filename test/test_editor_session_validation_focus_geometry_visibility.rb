# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  def self.active_model
    nil
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditModeDialog; end unless const_defined?(:EditModeDialog)
      class IndoorModeScreenOverlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.indoor_mode_screen_overlay'
      end unless const_defined?(:IndoorModeScreenOverlay)
      class DualGraphSpaceOverlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.dual_graph_space_overlay'
      end unless const_defined?(:DualGraphSpaceOverlay)
      module CellSpaceType
        LABELS = {} unless const_defined?(:LABELS)
      end unless const_defined?(:CellSpaceType)
    end
  end
end

require_relative '../indoor3d/application/storey_filter'
require_relative '../indoor3d/infrastructure/scene/editor_session'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionValidationFocusGeometryVisibilityTest < Minitest::Test
        def test_set_geometry_visible_keeps_user_preference_but_uses_fix_mode_visibility
          session = EditorSession.allocate
          calls = []
          writes = []
          session.instance_variable_set(:@geometry_visible, true)
          session.instance_variable_set(:@editing, true)
          session.define_singleton_method(:write_model_boolean_attribute) { |key, value| writes << [key, value] }
          session.define_singleton_method(:validation_focus_active?) { true }
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :apply_validation_focus_visibility }
          session.define_singleton_method(:apply_geometry_visibility) { raise 'normal geometry visibility should not run in fix mode' }
          session.define_singleton_method(:apply_edit_mode_visibility_filter) { raise 'edit filter should not run in fix mode' }
          session.define_singleton_method(:normalize_visibility_for_non_edit_mode) { raise 'normal mode visibility should not run in fix mode' }

          assert_equal false, session.set_geometry_visible(false)

          assert_equal false, session.geometry_visible?
          assert_equal [[EditorSession::GEOMETRY_VISIBLE_ATTRIBUTE, false]], writes
          assert_equal [:apply_validation_focus_visibility], calls
        end

        def test_apply_current_geometry_visibility_uses_edit_rules_while_editing
          session = EditorSession.allocate
          calls = []
          session.instance_variable_set(:@editing, true)
          session.define_singleton_method(:validation_focus_active?) { false }
          session.define_singleton_method(:apply_geometry_visibility) { calls << :apply_geometry_visibility }
          session.define_singleton_method(:apply_edit_mode_visibility_filter) { calls << :apply_edit_mode_visibility_filter }
          session.define_singleton_method(:apply_validation_focus_visibility) { raise 'fix visibility should not run outside fix mode' }
          session.define_singleton_method(:normalize_visibility_for_non_edit_mode) { raise 'normal mode visibility should not run while editing' }

          session.apply_current_geometry_visibility

          assert_equal [:apply_geometry_visibility, :apply_edit_mode_visibility_filter], calls
        end

        def test_apply_display_state_normalizes_when_not_editing_or_fix_mode
          session = EditorSession.allocate
          calls = []
          session.instance_variable_set(:@editing, false)
          session.instance_variable_set(:@dual_overlay_visible, true)
          session.define_singleton_method(:set_dual_overlay_visible) { |visible| calls << [:set_dual_overlay_visible, visible] }
          session.define_singleton_method(:validation_focus_active?) { false }
          session.define_singleton_method(:normalize_visibility_for_non_edit_mode) { calls << :normalize_visibility_for_non_edit_mode }
          session.define_singleton_method(:apply_geometry_visibility) { raise 'raw geometry visibility should not be the display entry point' }
          session.define_singleton_method(:apply_validation_focus_visibility) { raise 'fix visibility should not run outside fix mode' }

          session.apply_display_state

          assert_equal [[:set_dual_overlay_visible, true], :normalize_visibility_for_non_edit_mode], calls
        end

        def test_begin_validation_focus_editing_defers_visibility_reapply_after_edit_mode_start
          session = EditorSession.allocate
          calls = []
          session.instance_variable_set(:@editing, false)
          session.instance_variable_set(:@validation_focus_controller, fake_validation_focus_controller(calls))
          session.define_singleton_method(:capture_and_apply_validation_focus_rendering_options) { |count| calls << [:rendering, count] }
          session.define_singleton_method(:begin_editing) { calls << :begin_editing; true }
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :apply_validation_focus_visibility }
          session.define_singleton_method(:defer_validation_focus_visibility) { calls << :defer_validation_focus_visibility }
          session.define_singleton_method(:invalidate_overlay_transition_points) { calls << :invalidate_overlay_transition_points }
          session.define_singleton_method(:selection_changed) { calls << :selection_changed }
          session.define_singleton_method(:invalidate_view) { |_model| calls << :invalidate_view }

          assert_equal true, session.begin_validation_focus_editing(%w[cell_A cell_B])

          assert_equal [
            [:begin, %w[cell_A cell_B]],
            [:rendering, 2],
            :begin_editing,
            :apply_validation_focus_visibility,
            :defer_validation_focus_visibility,
            :invalidate_overlay_transition_points,
            :selection_changed,
            :invalidate_view
          ], calls
        end

        def test_begin_validation_focus_editing_rolls_back_when_visibility_apply_fails
          session = EditorSession.allocate
          calls = []
          session.instance_variable_set(:@editing, false)
          session.instance_variable_set(:@validation_focus_controller, fake_validation_focus_controller(calls))
          session.define_singleton_method(:capture_and_apply_validation_focus_rendering_options) { |count| calls << [:rendering, count] }
          session.define_singleton_method(:begin_editing) { calls << :begin_editing; true }
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :apply_validation_focus_visibility; false }
          session.define_singleton_method(:restore_validation_focus_visibility) { calls << :restore_validation_focus_visibility }
          session.define_singleton_method(:restore_validation_focus_rendering_options) { calls << :restore_validation_focus_rendering_options }
          session.define_singleton_method(:clear_validation_focus) { calls << :clear_validation_focus }
          session.define_singleton_method(:defer_validation_focus_visibility) { raise 'defer should not run after failed visibility' }
          session.define_singleton_method(:invalidate_overlay_transition_points) { raise 'overlay should not update after failed visibility' }
          session.define_singleton_method(:selection_changed) { raise 'selection should not update after failed visibility' }
          session.define_singleton_method(:invalidate_view) { |_model| raise 'view should not invalidate after failed visibility' }

          assert_equal false, session.begin_validation_focus_editing(%w[cell_A cell_B])

          assert_equal [
            [:begin, %w[cell_A cell_B]],
            [:rendering, 2],
            :begin_editing,
            :apply_validation_focus_visibility,
            :restore_validation_focus_visibility,
            :restore_validation_focus_rendering_options,
            :clear_validation_focus
          ], calls
        end

        def test_deferred_validation_focus_visibility_reapplies_across_startup_timers
          session = EditorSession.allocate
          calls = []
          session.instance_variable_set(:@editing, true)
          session.define_singleton_method(:validation_focus_active?) { true }
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :apply_validation_focus_visibility; true }
          session.define_singleton_method(:invalidate_overlay_transition_points) { calls << :invalidate_overlay_transition_points }
          session.define_singleton_method(:selection_changed) { calls << :selection_changed }
          session.define_singleton_method(:invalidate_view) { |model| calls << [:invalidate_view, model] }

          timers = with_fake_ui_timers do |scheduled_timers|
            assert_equal true, session.send(:defer_validation_focus_visibility)
            scheduled_timers
          end

          assert_equal EditorSession::VALIDATION_FOCUS_VISIBILITY_REAPPLY_DELAYS, timers.map(&:first)
          assert_equal [false] * timers.length, timers.map { |timer| timer[1] }

          timers.each { |timer| timer[2].call }

          expected_calls = EditorSession::VALIDATION_FOCUS_VISIBILITY_REAPPLY_DELAYS.flat_map do
            [
              :apply_validation_focus_visibility,
              :invalidate_overlay_transition_points,
              :selection_changed,
              [:invalidate_view, nil]
            ]
          end
          assert_equal expected_calls, calls
        end

        def test_active_path_changed_schedules_fix_mode_visibility_reapply
          session = EditorSession.allocate
          calls = []
          session.instance_variable_set(:@editing, true)
          session.instance_variable_set(:@indoor_model, fake_indoor_model(calls))
          session.instance_variable_set(:@active_path_controller, fake_active_path_controller_for_change(calls))
          session.define_singleton_method(:validation_focus_active?) { true }
          session.define_singleton_method(:defer_validation_focus_visibility) { calls << :defer_validation_focus_visibility; true }

          session.active_path_changed(:model)

          assert_equal [
            [:active_path_changed, :model, true],
            :defer_validation_focus_visibility
          ], calls
        end

        def test_set_validation_focus_highlight_returns_false_when_visibility_apply_fails
          session = EditorSession.allocate
          calls = []
          controller = Struct.new(:calls) do
            def set_highlight(ids, code)
              calls << [:set_highlight, ids, code]
              true
            end
          end.new(calls)
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :apply_validation_focus_visibility; false }
          session.define_singleton_method(:invalidate_view) { |_model| raise 'view should not invalidate after failed visibility' }

          assert_equal false, session.set_validation_focus_highlight(['cell_A'], '701')

          assert_equal [
            [:set_highlight, ['cell_A'], '701'],
            :apply_validation_focus_visibility
          ], calls
        end

        def test_row_selection_zooms_to_the_union_of_highlighted_cell_bounds_after_visibility
          calls = []
          view = fake_zoom_view
          cell_a = fake_zoom_cell('A', :bounds_a)
          cell_b = fake_zoom_cell('B', :bounds_b)
          indoor_model = Struct.new(:cell_spaces).new([cell_a, cell_b])
          controller = EditorSession::ValidationFocusController.new
          controller.begin(%w[cell_A cell_B])
          controller.set_focus_rows([{ id: 'row-1', cells: %w[A B], code: '203' }])
          session = EditorSession.allocate
          session.instance_variable_set(:@indoor_model, indoor_model)
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :visibility; true }
          session.define_singleton_method(:invalidate_overlay_transition_points) { calls << :overlay }
          session.define_singleton_method(:invalidate_view) { |_model| calls << :invalidate_view }

          with_fake_active_model(Struct.new(:active_view).new(view)) do
            with_fake_bounding_box do
              with_fake_ui_timers do |timers|
                assert session.set_validation_focus_highlight(
                  %w[cell_A cell_B],
                  '203',
                  row_id: 'row-1',
                  row_cells: %w[A B]
                )
                assert_equal [:visibility, :overlay, :invalidate_view], calls
                assert_equal 1, timers.length

                timers.first[2].call
              end
            end
          end

          assert_equal %i[bounds_a bounds_b], view.zoomed_bounds.items
          assert_equal true, view.invalidated
        end

        def test_row_selection_does_not_zoom_without_a_valid_cell_group
          view = fake_zoom_view
          indoor_model = Struct.new(:cell_spaces).new([fake_zoom_cell('A', nil)])
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{ id: 'row-1', cells: ['A'], code: '203' }])
          session = EditorSession.allocate
          session.instance_variable_set(:@indoor_model, indoor_model)
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) { true }
          session.define_singleton_method(:invalidate_overlay_transition_points) {}
          session.define_singleton_method(:invalidate_view) { |_model| }

          with_fake_active_model(Struct.new(:active_view).new(view)) do
            with_fake_bounding_box do
              with_fake_ui_timers do |timers|
                session.set_validation_focus_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])
                timers.first[2].call
              end
            end
          end

          assert_nil view.zoomed_bounds
          assert_equal false, view.invalidated
        end

        def test_highlight_clear_does_not_schedule_zoom
          session = EditorSession.allocate
          calls = []
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :visibility; true }
          session.define_singleton_method(:invalidate_overlay_transition_points) { calls << :overlay }
          session.define_singleton_method(:invalidate_view) { |_model| calls << :invalidate_view }

          with_fake_ui_timers do |timers|
            assert session.set_validation_focus_highlight([], '')
            assert_empty timers
          end

          assert_equal [:visibility, :overlay, :invalidate_view], calls
        end

        def test_validation_focus_row_mutation_publishes_only_the_final_replacement
          updates = []
          calls = []
          old_cell = fake_mutation_cell('A')
          new_cell = fake_mutation_cell('B')
          indoor_model = Struct.new(:cell_spaces, :updates) do
            def update_validation_focus_report_row(payload)
              updates << payload
            end
          end.new([new_cell], updates)
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{ id: 'row-1', cells: ['A'], states: ['S1'], transitions: ['T1'], code: '203' }])
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])
          session = EditorSession.allocate
          session.instance_variable_set(:@indoor_model, indoor_model)
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :visibility; true }
          session.define_singleton_method(:invalidate_overlay_transition_points) { calls << :overlay }
          session.define_singleton_method(:invalidate_view) { |_model| calls << :invalidate_view }
          session.define_singleton_method(:zoom_validation_focus_highlight) { |row_id:| calls << [:zoom, row_id]; true }

          session.with_validation_focus_row_mutation do
            assert_equal [], session.remove_validation_focus_highlight_cell(old_cell)
            assert_nil session.add_validation_focus_highlight_cell(new_cell)
            assert_empty updates
          end

          assert_equal 1, updates.length
          assert_equal 'row-1', updates.first[:row_id]
          assert_equal ['B'], updates.first[:cells]
          assert_equal ['S1'], updates.first[:states]
          assert_equal ['T1'], updates.first[:transitions]
          assert_equal 'cell_B', updates.first[:label]
          assert_equal [:visibility, :overlay, :invalidate_view, [:zoom, 'row-1']], calls
        end

        def test_discarded_validation_focus_row_mutation_does_not_publish_created_cells
          updates = []
          new_cell = fake_mutation_cell('B')
          indoor_model = Struct.new(:cell_spaces, :updates) do
            def update_validation_focus_report_row(payload)
              updates << payload
            end
          end.new([new_cell], updates)
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{ id: 'row-1', cells: ['A'], code: '203' }])
          controller.set_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])
          session = EditorSession.allocate
          session.instance_variable_set(:@indoor_model, indoor_model)
          session.instance_variable_set(:@validation_focus_controller, controller)

          session.with_validation_focus_row_mutation do
            session.add_validation_focus_highlight_cell(new_cell)
            session.discard_validation_focus_row_mutation
          end

          assert_empty updates
          assert_equal false, controller.visible_cell_space?(new_cell)
        end

        def test_set_visibility_filter_is_ignored_in_fix_mode
          session = EditorSession.allocate
          calls = []
          session.define_singleton_method(:validation_focus_active?) { true }
          session.define_singleton_method(:visibility_controller) { raise 'filter state should not change in fix mode' }
          session.define_singleton_method(:apply_edit_mode_visibility_filter) { raise 'edit filter should not run in fix mode' }
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :apply_validation_focus_visibility }

          assert_equal true, session.set_visibility_filter(storeys: ['F01'], cell_types: ['Room'])

          assert_equal [], calls
        end

        def test_refresh_visibility_filter_reapplies_fix_visibility_in_fix_mode
          session = EditorSession.allocate
          calls = []
          session.define_singleton_method(:validation_focus_active?) { true }
          session.define_singleton_method(:invalidate_overlay_transition_points) { calls << :invalidate_overlay_transition_points }
          session.define_singleton_method(:apply_validation_focus_visibility) { calls << :apply_validation_focus_visibility }
          session.define_singleton_method(:apply_edit_mode_visibility_filter) { raise 'edit filter should not run in fix mode' }

          session.refresh_visibility_filter

          assert_equal [
            :invalidate_overlay_transition_points,
            :apply_validation_focus_visibility
          ], calls
        end

        def test_close_dialog_only_uses_non_edit_visibility_normalization
          session = EditorSession.allocate
          calls = []
          session.instance_variable_set(:@editing, true)
          session.instance_variable_set(:@dialog, fake_dialog(calls))
          session.instance_variable_set(:@active_path_controller, fake_active_path_controller(calls))
          session.define_singleton_method(:validation_focus_active?) { true }
          session.define_singleton_method(:restore_validation_focus_visibility) { calls << :restore_validation_focus_visibility }
          session.define_singleton_method(:normalize_visibility_for_non_edit_mode) { calls << :normalize_visibility_for_non_edit_mode }
          session.define_singleton_method(:restore_validation_focus_rendering_options) { calls << :restore_validation_focus_rendering_options }
          session.define_singleton_method(:reset_edit_mode_visibility_filter) { calls << :reset_edit_mode_visibility_filter }
          session.define_singleton_method(:clear_validation_focus) { calls << :clear_validation_focus }
          session.define_singleton_method(:set_overlay_enabled) { |enabled| calls << [:set_overlay_enabled, enabled] }

          session.close_dialog_only

          assert_equal [
            :close_without_finish,
            :restore_validation_focus_visibility,
            :normalize_visibility_for_non_edit_mode,
            :active_path_reset,
            :restore_validation_focus_rendering_options,
            :reset_edit_mode_visibility_filter,
            :clear_validation_focus,
            [:set_overlay_enabled, false]
          ], calls
        end

        private

        def fake_validation_focus_controller(calls)
          Struct.new(:calls) do
            def begin(ids)
              calls << [:begin, ids]
              true
            end
          end.new(calls)
        end

        def fake_dialog(calls)
          Struct.new(:calls) do
            def close_without_finish
              calls << :close_without_finish
            end
          end.new(calls)
        end

        def fake_active_path_controller(calls)
          Struct.new(:calls) do
            def reset
              calls << :active_path_reset
            end
          end.new(calls)
        end

        def fake_indoor_model(_calls)
          Struct.new(:calls) do
            def transaction_replay_pending?
              false
            end
          end.new(_calls)
        end

        def fake_active_path_controller_for_change(calls)
          Struct.new(:calls) do
            def active_path_changed(model, editing:, reenter:)
              calls << [:active_path_changed, model, editing]
              reenter
            end
          end.new(calls)
        end

        def fake_zoom_cell(id, bounds)
          group = if bounds
                    Struct.new(:bounds) do
                      def valid?
                        true
                      end
                    end.new(bounds)
                  end
          Struct.new(:id, :valid_sketchup_group) do
            def valid?
              true
            end
          end.new(id, group)
        end

        def fake_mutation_cell(id)
          Struct.new(:id) do
            def valid?
              true
            end
          end.new(id)
        end

        def fake_zoom_view
          Struct.new(:zoomed_bounds, :invalidated) do
            def zoom(bounds)
              self.zoomed_bounds = bounds
            end

            def invalidate
              self.invalidated = true
            end
          end.new(nil, false)
        end

        def with_fake_active_model(model)
          original = Sketchup.method(:active_model)
          Sketchup.define_singleton_method(:active_model) { model }
          yield
        ensure
          Sketchup.define_singleton_method(:active_model) { |*args| original.call(*args) }
        end

        def with_fake_bounding_box
          geom_existed = Object.const_defined?(:Geom, false)
          geom = geom_existed ? Object.const_get(:Geom) : Module.new
          Object.const_set(:Geom, geom) unless geom_existed
          bounds_existed = geom.const_defined?(:BoundingBox, false)
          previous_bounds = geom.const_get(:BoundingBox) if bounds_existed
          geom.send(:remove_const, :BoundingBox) if bounds_existed
          fake_bounds = Class.new do
            attr_reader :items

            def initialize
              @items = []
            end

            def add(bounds)
              @items << bounds
            end
          end
          geom.const_set(:BoundingBox, fake_bounds)
          yield
        ensure
          geom.send(:remove_const, :BoundingBox) if geom&.const_defined?(:BoundingBox, false)
          geom.const_set(:BoundingBox, previous_bounds) if bounds_existed
          Object.send(:remove_const, :Geom) unless geom_existed
        end

        def with_fake_ui_timers
          previous_defined = Object.const_defined?(:UI, false)
          previous_ui = Object.const_get(:UI) if previous_defined
          Object.send(:remove_const, :UI) if previous_defined

          scheduled_timers = []
          fake_ui = Module.new
          fake_ui.define_singleton_method(:start_timer) do |interval, repeat, &block|
            scheduled_timers << [interval, repeat, block]
            true
          end
          Object.const_set(:UI, fake_ui)

          yield scheduled_timers
        ensure
          Object.send(:remove_const, :UI) if Object.const_defined?(:UI, false)
          Object.const_set(:UI, previous_ui) if previous_defined
        end
      end
    end
  end
end
