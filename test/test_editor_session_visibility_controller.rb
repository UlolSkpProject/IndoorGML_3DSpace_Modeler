# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/editor_session/visibility_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionVisibilityControllerTest < Minitest::Test
        def test_filter_state_is_stored_and_reset_without_hidden_snapshots
          controller = EditorSession::VisibilityController.new
          assert controller.set_filter(storeys: %w[1F B1], cell_types: [:general])
          refute controller.set_filter(storeys: %w[1F B1], cell_types: [:general])

          assert_equal %w[1F B1], controller.visible_storeys
          assert_equal [:general], controller.visible_cell_types
          assert controller.filter_active?
          refute_respond_to controller, :remember_edit_mode_visibility
          refute_respond_to controller, :edit_mode_visibility_snapshot

          controller.reset_filter

          assert_empty controller.visible_storeys
          assert_empty controller.visible_cell_types
          refute controller.filter_active?
        end

        def test_set_hidden_and_visible_changes_group_only
          visible_child = fake_child(hidden: false)
          hidden_child = fake_child(hidden: true)
          group = fake_group(pid: 10, children: [visible_child, hidden_child])
          controller = EditorSession::VisibilityController.new

          controller.set_cell_space_render_visible(group, false)
          assert_equal true, group.hidden?
          assert_equal false, visible_child.hidden?
          assert_equal true, hidden_child.hidden?
          assert_equal 0, visible_child.write_count
          assert_equal 0, hidden_child.write_count

          controller.set_cell_space_render_visible(group, true)
          assert_equal false, group.hidden?
          assert_equal false, visible_child.hidden?
          assert_equal true, hidden_child.hidden?
          assert_equal 0, visible_child.write_count
          assert_equal 0, hidden_child.write_count
        end

        def test_set_visible_shows_group_without_touching_children
          visible_child = fake_child(hidden: false)
          hidden_child = fake_child(hidden: true)
          group = fake_group(pid: 11, children: [visible_child, hidden_child], hidden: true)
          controller = EditorSession::VisibilityController.new

          controller.set_cell_space_render_visible(group, true)

          assert_equal false, group.hidden?
          assert_equal false, visible_child.hidden?
          assert_equal true, hidden_child.hidden?
          assert_equal 0, visible_child.write_count
          assert_equal 0, hidden_child.write_count
        end

        def test_set_render_visibility_changes_group_only
          hidden_child = fake_child(hidden: true)
          visible_child = fake_child(hidden: false)
          group = fake_group(pid: 13, children: [hidden_child, visible_child])
          controller = EditorSession::VisibilityController.new

          controller.set_cell_space_render_visible(group, false)

          assert_equal true, group.hidden?
          assert_equal 1, group.write_count
          assert_equal 0, hidden_child.write_count
          assert_equal 0, visible_child.write_count
          assert_equal true, hidden_child.hidden?
          assert_equal false, visible_child.hidden?
        end

        def test_visibility_target_check_does_not_scan_child_entities
          child = fake_child(hidden: false)
          group = fake_group(pid: 14, children: [child], raise_on_entities: true)
          controller = EditorSession::VisibilityController.new

          assert_equal true, controller.cell_space_visibility_target?(group)

          assert_equal 0, child.write_count
        end

        def test_set_render_visibility_returns_false_for_invalid_target
          group = fake_group(pid: 12, hidden: false)
          controller = EditorSession::VisibilityController.new

          group.define_singleton_method(:valid?) { false }

          assert_equal false, controller.set_cell_space_render_visible(group, false)
          assert_equal false, group.hidden?
        end

        private

        def fake_child(hidden:)
          Class.new do
            def initialize(hidden)
              @hidden = hidden
              @write_count = 0
            end

            attr_reader :write_count

            def valid?
              true
            end

            def hidden?
              @hidden == true
            end

            def hidden=(value)
              @write_count += 1
              @hidden = value == true
            end
          end.new(hidden)
        end

        def fake_group(pid:, children: [fake_child(hidden: false)], hidden: false, raise_on_entities: false)
          Class.new do
            def initialize(pid, children, hidden, raise_on_entities)
              @pid = pid
              @children = children
              @hidden = hidden
              @write_count = 0
              @raise_on_entities = raise_on_entities
            end

            attr_reader :write_count

            def valid?
              true
            end

            def persistent_id
              @pid
            end

            def visible?
              !hidden?
            end

            def visible=(value)
              self.hidden = value != true
            end

            def hidden?
              @hidden == true
            end

            def hidden=(value)
              @write_count += 1
              @hidden = value == true
            end

            def entities
              raise 'entities should not be scanned' if @raise_on_entities

              @children
            end
          end.new(pid, children, hidden, raise_on_entities)
        end
      end
    end
  end
end
