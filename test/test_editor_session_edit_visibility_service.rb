# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/application/storey_filter'
require_relative '../indoor3d/infrastructure/scene/editor_session/visibility_controller'
require_relative '../indoor3d/infrastructure/scene/editor_session/validation_focus_controller'
require_relative '../indoor3d/infrastructure/scene/editor_session/edit_visibility_service'

module Sketchup
  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionEditVisibilityServiceTest < Minitest::Test
        def teardown
          Sketchup.test_active_model = nil
        end

        def test_visibility_filter_hides_nonmatching_cell_spaces_and_clear_shows_all
          matching_child = fake_child(hidden: false)
          hidden_child = fake_child(hidden: false)
          matching_group = fake_group(pid: 1, children: [matching_child])
          hidden_group = fake_group(pid: 2, children: [hidden_child])
          indoor_model = fake_indoor_model(
            cell_spaces: [
              fake_cell_space(group: matching_group, storey: 'F01', cell_type: :general),
              fake_cell_space(group: hidden_group, storey: 'F02', cell_type: :general)
            ]
          )
          visibility = EditorSession::VisibilityController.new
          visibility.set_filter(storeys: ['F01'], cell_types: [])
          callbacks = CallbackLog.new
          Sketchup.test_active_model = fake_model

          service = build_service(indoor_model, visibility, callbacks)

          assert service.apply_edit_mode_visibility_filter
          assert_equal false, matching_group.hidden?
          assert_equal true, hidden_group.hidden?
          assert_equal false, matching_child.hidden?
          assert_equal false, hidden_child.hidden?
          assert_equal 0, matching_child.write_count
          assert_equal 0, hidden_child.write_count
          assert_equal 1, callbacks.invalidated

          assert service.apply_all_edit_mode_cell_space_visibility
          assert_equal false, matching_group.hidden?
          assert_equal false, hidden_group.hidden?
          assert_equal false, matching_child.hidden?
          assert_equal false, hidden_child.hidden?
          assert_equal 0, matching_child.write_count
          assert_equal 0, hidden_child.write_count
        end

        def test_geometry_visibility_updates_primal_group_inside_unlock_scope
          primal = fake_group(pid: 99)
          indoor_model = fake_indoor_model(primal_group: primal)
          callbacks = CallbackLog.new
          Sketchup.test_active_model = fake_model

          service = build_service(
            indoor_model,
            EditorSession::VisibilityController.new,
            callbacks,
            geometry_visible: -> { false }
          )

          assert service.apply_geometry_visibility
          assert_equal false, primal.visible?
          assert_equal [primal], callbacks.unlocked_entities
          assert_equal 1, callbacks.invalidated
        end

        def test_validation_focus_limits_visible_cell_spaces
          focused_child = fake_child(hidden: false)
          hidden_child = fake_child(hidden: false)
          focused_group = fake_group(pid: 10, children: [focused_child])
          hidden_group = fake_group(pid: 11, children: [hidden_child])
          focused_cell = fake_cell_space(id: 'A', group: focused_group, storey: 'F01', cell_type: :general)
          hidden_cell = fake_cell_space(id: 'B', group: hidden_group, storey: 'F01', cell_type: :general)
          indoor_model = fake_indoor_model(cell_spaces: [focused_cell, hidden_cell])
          validation = EditorSession::ValidationFocusController.new
          validation.begin(['cell_A'])

          service = build_service(
            indoor_model,
            EditorSession::VisibilityController.new,
            CallbackLog.new,
            validation: validation
          )

          assert service.apply_validation_focus_visibility
          assert_equal false, focused_group.hidden?
          assert_equal true, hidden_group.hidden?
          assert_equal false, focused_child.hidden?
          assert_equal false, hidden_child.hidden?
          assert_equal 0, focused_child.write_count
          assert_equal 0, hidden_child.write_count
        end

        def test_validation_focus_matches_cell_space_id_that_already_has_cell_prefix
          focused_group = fake_group(pid: 12)
          hidden_group = fake_group(pid: 13)
          focused_cell = fake_cell_space(id: 'cell_A', group: focused_group, storey: 'F01', cell_type: :general)
          hidden_cell = fake_cell_space(id: 'cell_B', group: hidden_group, storey: 'F01', cell_type: :general)
          indoor_model = fake_indoor_model(cell_spaces: [focused_cell, hidden_cell])
          validation = EditorSession::ValidationFocusController.new
          validation.begin(['cell_A'])

          service = build_service(
            indoor_model,
            EditorSession::VisibilityController.new,
            CallbackLog.new,
            validation: validation
          )

          assert service.apply_validation_focus_visibility
          assert_equal false, focused_group.hidden?
          assert_equal true, hidden_group.hidden?
        end

        def test_validation_focus_forces_primal_group_visible_even_when_geometry_is_hidden
          primal = fake_group(pid: 29, hidden: true)
          focused_group = fake_group(pid: 30)
          outside_group = fake_group(pid: 31)
          focused_cell = fake_cell_space(id: 'A', group: focused_group, storey: 'F01', cell_type: :general)
          outside_cell = fake_cell_space(id: 'B', group: outside_group, storey: 'F01', cell_type: :general)
          indoor_model = fake_indoor_model(
            primal_group: primal,
            cell_spaces: [focused_cell, outside_cell]
          )
          validation = EditorSession::ValidationFocusController.new
          validation.begin(['cell_A'])
          callbacks = CallbackLog.new
          Sketchup.test_active_model = fake_model

          service = build_service(
            indoor_model,
            EditorSession::VisibilityController.new,
            callbacks,
            geometry_visible: -> { false },
            validation: validation
          )

          assert service.apply_validation_focus_visibility
          assert_equal true, primal.visible?
          assert_equal false, focused_group.hidden?
          assert_equal true, outside_group.hidden?
          assert_includes callbacks.unlocked_entities, primal
        end

        def test_validation_focus_overrides_edit_visibility_filters
          visible_error_group = fake_group(pid: 30)
          filtered_error_group = fake_group(pid: 31)
          outside_group = fake_group(pid: 32)
          visible_error = fake_cell_space(id: 'A', group: visible_error_group, storey: 'F01', cell_type: :general)
          filtered_error = fake_cell_space(id: 'B', group: filtered_error_group, storey: 'F02', cell_type: :general)
          outside = fake_cell_space(id: 'C', group: outside_group, storey: 'F02', cell_type: :general)
          indoor_model = fake_indoor_model(cell_spaces: [visible_error, filtered_error, outside])
          visibility = EditorSession::VisibilityController.new
          visibility.set_filter(storeys: ['F01'], cell_types: [])
          validation = EditorSession::ValidationFocusController.new
          validation.begin(%w[cell_A cell_B])

          service = build_service(indoor_model, visibility, CallbackLog.new, validation: validation)

          assert service.apply_validation_focus_visibility
          assert_equal false, visible_error_group.hidden?
          assert_equal false, filtered_error_group.hidden?
          assert_equal true, outside_group.hidden?
        end

        def test_validation_focus_highlight_and_clear_ignore_edit_visibility_filters
          visible_error_group = fake_group(pid: 33)
          highlighted_error_group = fake_group(pid: 34)
          outside_group = fake_group(pid: 35)
          visible_error = fake_cell_space(id: 'A', group: visible_error_group, storey: 'F01', cell_type: :general)
          highlighted_error = fake_cell_space(id: 'B', group: highlighted_error_group, storey: 'F02', cell_type: :general)
          outside = fake_cell_space(id: 'C', group: outside_group, storey: 'F02', cell_type: :general)
          indoor_model = fake_indoor_model(cell_spaces: [visible_error, highlighted_error, outside])
          visibility = EditorSession::VisibilityController.new
          visibility.set_filter(storeys: ['F01'], cell_types: [])
          validation = EditorSession::ValidationFocusController.new
          validation.begin(%w[cell_A cell_B])
          validation.set_highlight(['cell_B'], '701')

          service = build_service(indoor_model, visibility, CallbackLog.new, validation: validation)

          assert service.apply_validation_focus_visibility
          assert_equal true, visible_error_group.hidden?
          assert_equal false, highlighted_error_group.hidden?
          assert_equal true, outside_group.hidden?

          validation.set_highlight([], '')
          assert service.apply_validation_focus_visibility
          assert_equal false, visible_error_group.hidden?
          assert_equal false, highlighted_error_group.hidden?
          assert_equal true, outside_group.hidden?
        end

        def test_validation_focus_highlight_solid_cell_ref_unhides_target_cell_space
          target_group = fake_group(pid: 36, hidden: true)
          outside_group = fake_group(pid: 37)
          target = fake_cell_space(id: 'b67d90rs', group: target_group, storey: 'F01', cell_type: :general)
          outside = fake_cell_space(id: 'outside', group: outside_group, storey: 'F01', cell_type: :general)
          indoor_model = fake_indoor_model(cell_spaces: [target, outside])
          validation = EditorSession::ValidationFocusController.new
          validation.begin(%w[cell_b67d90rs cell_outside])
          validation.set_highlight(['solid_cell_b67d90rs'], '203')

          service = build_service(indoor_model, EditorSession::VisibilityController.new, CallbackLog.new, validation: validation)

          assert service.apply_validation_focus_visibility
          assert_equal false, target_group.hidden?
          assert_equal true, outside_group.hidden?
        end

        def test_apply_all_visibility_forces_group_visible_without_edit_mode_snapshots
          child = fake_child(hidden: true)
          group = fake_group(pid: 20, children: [child], hidden: true)
          indoor_model = fake_indoor_model(
            cell_spaces: [fake_cell_space(group: group, storey: 'F01', cell_type: :general)]
          )
          callbacks = CallbackLog.new
          Sketchup.test_active_model = fake_model
          service = build_service(indoor_model, EditorSession::VisibilityController.new, callbacks)

          assert service.apply_all_edit_mode_cell_space_visibility

          assert_equal false, group.hidden?
          assert_equal true, child.hidden?
          assert_equal 0, child.write_count
          assert_equal 1, group.write_count
          assert_equal 1, callbacks.invalidated
          assert_equal [group], callbacks.unlocked_entities
        end

        def test_normalize_visibility_for_non_edit_mode_forces_group_visible_without_snapshot
          child = fake_child(hidden: true)
          group = fake_group(pid: 21, children: [child], hidden: true)
          primal = fake_group(pid: 22)
          indoor_model = fake_indoor_model(
            primal_group: primal,
            cell_spaces: [fake_cell_space(group: group, storey: 'F01', cell_type: :general)]
          )
          callbacks = CallbackLog.new
          Sketchup.test_active_model = fake_model
          service = build_service(indoor_model, EditorSession::VisibilityController.new, callbacks)

          assert service.normalize_visibility_for_non_edit_mode

          assert_equal false, group.hidden?
          assert_equal true, child.hidden?
          assert_equal 0, child.write_count
          assert_equal 1, group.write_count
          assert_equal 1, callbacks.overlay_invalidated
          assert_equal [group, primal], callbacks.unlocked_entities
        end

        def test_restore_validation_focus_visibility_normalizes_without_hidden_snapshot
          focused_group = fake_group(pid: 23)
          outside_group = fake_group(pid: 24, hidden: true)
          primal = fake_group(pid: 25, hidden: false)
          indoor_model = fake_indoor_model(
            primal_group: primal,
            cell_spaces: [
              fake_cell_space(id: 'A', group: focused_group, storey: 'F01', cell_type: :general),
              fake_cell_space(id: 'B', group: outside_group, storey: 'F01', cell_type: :general)
            ]
          )
          callbacks = CallbackLog.new
          Sketchup.test_active_model = fake_model
          service = build_service(
            indoor_model,
            EditorSession::VisibilityController.new,
            callbacks,
            geometry_visible: -> { false }
          )

          assert service.restore_validation_focus_visibility

          assert_equal false, focused_group.hidden?
          assert_equal false, outside_group.hidden?
          assert_equal false, primal.visible?
          assert_includes callbacks.unlocked_entities, focused_group
          assert_includes callbacks.unlocked_entities, outside_group
          assert_includes callbacks.unlocked_entities, primal
        end

        def test_normalize_visibility_for_non_edit_mode_forces_group_visible_even_when_cached_hidden
          child = fake_child(hidden: true)
          group = fake_group(pid: 26, children: [child])
          primal = fake_group(pid: 27)
          indoor_model = fake_indoor_model(
            primal_group: primal,
            cell_spaces: [fake_cell_space(group: group, storey: 'F01', cell_type: :general)]
          )
          visibility = EditorSession::VisibilityController.new
          visibility.set_cell_space_render_visible(group, false)
          callbacks = CallbackLog.new
          Sketchup.test_active_model = fake_model
          service = build_service(indoor_model, visibility, callbacks)

          assert service.normalize_visibility_for_non_edit_mode

          assert_equal false, group.hidden?
          assert_equal true, child.hidden?
          assert_equal 0, child.write_count
          assert_equal 2, group.write_count
        end

        private

        def build_service(indoor_model, visibility, callbacks, geometry_visible: -> { true }, validation: EditorSession::ValidationFocusController.new)
          EditorSession::EditVisibilityService.new(
            indoor_model: indoor_model,
            visibility_controller: visibility,
            validation_focus_controller: validation,
            geometry_visible: geometry_visible,
            with_unlocked: ->(entity, &block) { callbacks.unlock(entity, &block) },
            invalidate_view: ->(_model) { callbacks.invalidate },
            invalidate_overlay: -> { callbacks.invalidate_overlay }
          )
        end

        def fake_model
          Class.new do
            attr_reader :commits, :aborts

            def initialize
              @commits = 0
              @aborts = 0
            end

            def active_operation_name
              ''
            end

            def start_operation(_name, _transparent)
              true
            end

            def commit_operation
              @commits += 1
            end

            def abort_operation
              @aborts += 1
            end
          end.new
        end

        def fake_indoor_model(primal_group: fake_group(pid: 0), cell_spaces: [])
          Struct.new(:primal_group, :cell_spaces) do
            def with_runtime_observer_suppression
              yield
            end
          end.new(primal_group, cell_spaces)
        end

        def fake_cell_space(id: nil, group:, storey:, cell_type:)
          Struct.new(:id, :sketchup_group, :storey, :cell_type) do
            def valid?
              true
            end
          end.new(id, group, storey, cell_type)
        end

        def fake_group(pid:, children: [fake_child(hidden: false)], hidden: false)
          Class.new do
            def initialize(pid, children, hidden)
              @pid = pid
              @children = children
              @hidden = hidden
              @write_count = 0
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
              @children
            end
          end.new(pid, children, hidden)
        end

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

        class CallbackLog
          attr_reader :invalidated, :overlay_invalidated, :unlocked_entities

          def initialize
            @invalidated = 0
            @overlay_invalidated = 0
            @unlocked_entities = []
          end

          def unlock(entity)
            @unlocked_entities << entity
            yield
          end

          def invalidate
            @invalidated += 1
          end

          def invalidate_overlay
            @overlay_invalidated += 1
          end
        end
      end
    end
  end
end
