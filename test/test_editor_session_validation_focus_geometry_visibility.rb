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
      class EditModeOverlay; end unless const_defined?(:EditModeOverlay)
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
          session.define_singleton_method(:restore_edit_mode_visibility) { raise 'edit filter snapshots should not be restored on fix-mode close' }
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
      end
    end
  end
end
