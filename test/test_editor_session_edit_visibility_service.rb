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

        def test_visibility_filter_hides_nonmatching_cell_spaces_and_restores_snapshot
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
          assert_equal false, matching_child.hidden?
          assert_equal true, hidden_child.hidden?
          assert_equal 1, callbacks.invalidated

          assert service.apply_all_edit_mode_cell_space_visibility
          assert_equal false, matching_child.hidden?
          assert_equal false, hidden_child.hidden?
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
          assert_equal false, focused_child.hidden?
          assert_equal true, hidden_child.hidden?
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
