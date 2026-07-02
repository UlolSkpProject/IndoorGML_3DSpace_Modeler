# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/editor_session/visibility_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionVisibilityControllerTest < Minitest::Test
        def test_filter_state_is_stored_and_reset_with_snapshots
          controller = EditorSession::VisibilityController.new
          group = fake_group(pid: 7)
          controller.set_filter(storeys: %w[1F B1], cell_types: [:general])
          controller.remember_edit_mode_visibility(group)

          assert_equal %w[1F B1], controller.visible_storeys
          assert_equal [:general], controller.visible_cell_types
          assert controller.filter_active?
          refute controller.edit_mode_visibility_snapshots_empty?

          controller.reset_filter

          assert_empty controller.visible_storeys
          assert_empty controller.visible_cell_types
          refute controller.filter_active?
          assert controller.edit_mode_visibility_snapshots_empty?
        end

        def test_capture_and_restore_child_hidden_state
          visible_child = fake_child(hidden: false)
          hidden_child = fake_child(hidden: true)
          group = fake_group(pid: 10, children: [visible_child, hidden_child])
          controller = EditorSession::VisibilityController.new
          snapshot = controller.capture_cell_space_visibility(group)

          controller.set_cell_space_render_visible(group, false)
          assert_equal true, visible_child.hidden?
          assert_equal true, hidden_child.hidden?

          controller.restore_cell_space_visibility(group, snapshot)
          assert_equal false, visible_child.hidden?
          assert_equal true, hidden_child.hidden?
        end

        def test_set_visible_with_snapshot_restores_instead_of_forcing_all_children_visible
          visible_child = fake_child(hidden: false)
          hidden_child = fake_child(hidden: true)
          group = fake_group(pid: 11, children: [visible_child, hidden_child])
          controller = EditorSession::VisibilityController.new
          snapshot = controller.capture_cell_space_visibility(group)

          controller.set_cell_space_render_visible(group, true, snapshot)

          assert_equal false, visible_child.hidden?
          assert_equal true, hidden_child.hidden?
        end

        def test_remember_edit_mode_visibility_prefers_validation_snapshot
          original_child = fake_child(hidden: false)
          validation_child = fake_child(hidden: true)
          group = fake_group(pid: 12, children: [original_child])
          validation_snapshot = {
            visible: true,
            children: [[validation_child, true]]
          }
          controller = EditorSession::VisibilityController.new

          controller.remember_edit_mode_visibility(group, snapshot: validation_snapshot)

          assert_same validation_snapshot, controller.edit_mode_visibility_snapshot(group)
        end

        private

        def fake_child(hidden:)
          Class.new do
            def initialize(hidden)
              @hidden = hidden
            end

            def valid?
              true
            end

            def hidden?
              @hidden == true
            end

            def hidden=(value)
              @hidden = value == true
            end
          end.new(hidden)
        end

        def fake_group(pid:, children: [fake_child(hidden: false)])
          Class.new do
            def initialize(pid, children)
              @pid = pid
              @children = children
              @visible = true
            end

            def valid?
              true
            end

            def persistent_id
              @pid
            end

            def visible?
              @visible == true
            end

            def visible=(value)
              @visible = value == true
            end

            def entities
              @children
            end
          end.new(pid, children)
        end
      end
    end
  end
end
