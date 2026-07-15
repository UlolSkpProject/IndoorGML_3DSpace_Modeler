# frozen_string_literal: true

require 'minitest/autorun'

module Geom
  Point3d = Struct.new(:x, :y, :z) do
    def distance(other)
      Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    end
  end unless const_defined?(:Point3d)

  Vector3d = Struct.new(:x, :y, :z) do
    def to_a
      [x, y, z]
    end
  end unless const_defined?(:Vector3d)
end

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
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
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

        def test_finish_synchronizes_dirty_validation_focus_topology_before_visibility_restore
          calls = []
          indoor_model = Class.new do
            define_method(:validation_focus_topology_dirty?) { true }
            define_method(:synchronize_validation_focus_topology_if_dirty) do
              calls << :sync_all
              true
            end
            define_method(:detach_edit_selection_observer) { |_model| calls << :detach }
          end.new
          indoor_model.singleton_class.send(:define_method, :calls) { calls }
          path_controller = Struct.new(:calls) do
            def prepare_for_finish(_model); calls << :prepare; end
            def reset_target; calls << :reset_target; end
            def close(_model); calls << :close_path; end
            def clear_previous_path; calls << :clear_path; end
          end.new(calls)
          session = EditorSession.allocate
          session.instance_variable_set(:@editing, true)
          session.instance_variable_set(:@indoor_model, indoor_model)
          session.instance_variable_set(:@dialog, Struct.new(:calls) { def close; calls << :close_dialog; end }.new(calls))
          session.define_singleton_method(:with_active_path_enforcement_suspended) { |&block| block.call }
          session.define_singleton_method(:active_path_controller) { path_controller }
          session.define_singleton_method(:restore_validation_focus_visibility) { calls << :restore_visibility }
          session.define_singleton_method(:normalize_visibility_for_non_edit_mode) { calls << :normalize_visibility }
          session.define_singleton_method(:reset_edit_mode_visibility_filter) { calls << :reset_filter }
          session.define_singleton_method(:restore_validation_focus_rendering_options) { calls << :restore_rendering }
          session.define_singleton_method(:clear_validation_focus) { calls << :clear_focus }
          session.define_singleton_method(:update_overlay_enabled) { calls << :overlay }
          session.define_singleton_method(:apply_lock_policy) { calls << :lock }
          session.define_singleton_method(:apply_geometry_visibility) { calls << :geometry }
          session.define_singleton_method(:invalidate_view) { |_model| calls << :invalidate }

          assert session.finish

          assert_equal :sync_all, calls.first
          assert_operator calls.index(:sync_all), :<, calls.index(:restore_visibility)
          assert_operator calls.index(:sync_all), :<, calls.index(:clear_focus)
        end

        def test_finish_keeps_edit_mode_active_when_dirty_topology_sync_fails
          indoor_model = Object.new
          indoor_model.define_singleton_method(:validation_focus_topology_dirty?) { true }
          indoor_model.define_singleton_method(:synchronize_validation_focus_topology_if_dirty) { false }
          session = EditorSession.allocate
          session.instance_variable_set(:@editing, true)
          session.instance_variable_set(:@indoor_model, indoor_model)
          session.define_singleton_method(:restore_validation_focus_visibility) do
            raise 'visibility must not be restored after failed topology sync'
          end

          refute session.finish
          assert session.editing?
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

        def test_row_selection_applies_visibility_then_top_iso_extents_and_padding_in_order
          calls = []
          camera_events = []
          view = fake_zoom_view(camera_events)
          cell_a = fake_zoom_cell('A', :bounds_a)
          cell_b = fake_zoom_cell('B', :bounds_b)
          controller = EditorSession::ValidationFocusController.new
          controller.begin(%w[cell_A cell_B])
          controller.set_focus_rows([{ id: 'row-1', cells: %w[A B], code: '203' }])
          session = EditorSession.allocate
          session.instance_variable_set(:@indoor_model, Struct.new(:cell_spaces).new([cell_a, cell_b]))
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) do
            calls << :visibility
            camera_events << :visibility
            true
          end
          session.define_singleton_method(:invalidate_overlay_transition_points) { calls << :overlay }
          session.define_singleton_method(:invalidate_view) { |_model| calls << :invalidate_view }

          with_fake_active_model(Struct.new(:active_view).new(view)) do
            with_fake_ui_timers do |timers|
              assert session.set_validation_focus_highlight(
                %w[cell_A cell_B],
                '203',
                row_id: 'row-1',
                row_cells: %w[A B]
              )
              assert_equal [:visibility, :overlay, :invalidate_view], calls
              assert_equal [[0, false]], timers.map { |delay, repeat, _block| [delay, repeat] }

              timers[0][2].call
              assert_equal 1, timers.length
            end
          end

          assert_equal [:visibility, :top_view, :isometric_view, :zoom_extents, [:zoom, 0.7], :invalidate], camera_events
          assert_equal [0.7], view.zoom_calls
          assert_equal true, view.invalidated
        end

        def test_row_selection_does_not_zoom_without_valid_cell_bounds
          view = fake_zoom_view
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{ id: 'row-1', cells: ['A'], code: '203' }])
          session = EditorSession.allocate
          session.instance_variable_set(:@indoor_model, Struct.new(:cell_spaces).new([fake_zoom_cell('A', nil)]))
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) { true }
          session.define_singleton_method(:invalidate_overlay_transition_points) {}
          session.define_singleton_method(:invalidate_view) { |_model| }

          with_fake_active_model(Struct.new(:active_view).new(view)) do
            with_fake_ui_timers do |timers|
              session.set_validation_focus_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])
              timers.first[2].call
            end
          end

          assert_empty view.zoom_calls
          assert_equal false, view.invalidated
        end

        def test_highlight_clear_cancels_pending_row_zoom
          view = fake_zoom_view
          cell = fake_zoom_cell('A', :bounds_a)
          controller = EditorSession::ValidationFocusController.new
          controller.begin(['cell_A'])
          controller.set_focus_rows([{ id: 'row-1', cells: ['A'], code: '203' }])
          session = EditorSession.allocate
          session.instance_variable_set(:@indoor_model, Struct.new(:cell_spaces).new([cell]))
          session.instance_variable_set(:@validation_focus_controller, controller)
          session.define_singleton_method(:apply_validation_focus_visibility) { true }
          session.define_singleton_method(:invalidate_overlay_transition_points) {}
          session.define_singleton_method(:invalidate_view) { |_model| }

          with_fake_active_model(Struct.new(:active_view).new(view)) do
            with_fake_ui_timers do |timers|
              session.set_validation_focus_highlight(['cell_A'], '203', row_id: 'row-1', row_cells: ['A'])
              session.set_validation_focus_highlight([], '')
              assert_equal 1, timers.length
              timers.first[2].call
            end
          end

          assert_empty view.zoom_calls
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

        def fake_zoom_view(events = [])
          camera = FakeZoomCamera.new(
            FakeZoomPoint.new(0.0, 0.0, 10.0),
            FakeZoomPoint.new(0.0, 0.0, 0.0),
            events,
            []
          )
          Struct.new(:zoom_calls, :invalidated, :events, :camera) do
            def zoom(value)
              unless value.is_a?(Array) || value.is_a?(Numeric)
                raise ArgumentError, 'expected an entity array or numeric zoom factor'
              end

              zoom_calls << value
              events << [:zoom, value]
            end

            def zoom_extents
              events << :zoom_extents
            end

            def invalidate
              self.invalidated = true
              events << :invalidate
            end
          end.new([], false, events, camera)
        end

        FakeZoomPoint = Geom::Point3d

        FakeZoomCamera = Struct.new(:eye, :target, :events, :set_calls) do
          def set(next_eye, next_target, up)
            set_calls << [next_eye, next_target, up]
            events << (up.to_a == [0.0, 1.0, 0.0] ? :top_view : :isometric_view)
            true
          end
        end

        def with_fake_active_model(model)
          original = Sketchup.method(:active_model)
          Sketchup.define_singleton_method(:active_model) { model }
          yield
        ensure
          Sketchup.define_singleton_method(:active_model) { |*args| original.call(*args) }
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
