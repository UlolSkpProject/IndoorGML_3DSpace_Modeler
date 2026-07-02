# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/editor_session/lock_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionLockControllerTest < Minitest::Test
        def test_lock_and_unlock_entity
          entity = fake_entity(locked: false)
          controller = EditorSession::LockController.new(indoor_model: fake_indoor_model)

          assert_equal true, controller.lock_entity(entity)
          assert_equal true, entity.locked?

          assert_equal true, controller.unlock_entity(entity)
          assert_equal false, entity.locked?
        end

        def test_with_unlocked_restores_previously_locked_entity
          entity = fake_entity(locked: true)
          controller = EditorSession::LockController.new(indoor_model: fake_indoor_model)
          locked_during_yield = nil

          controller.with_unlocked(entity) { locked_during_yield = entity.locked? }

          assert_equal false, locked_during_yield
          assert_equal true, entity.locked?
        end

        def test_with_unlocked_keeps_unlocked_entity_unlocked
          entity = fake_entity(locked: false)
          controller = EditorSession::LockController.new(indoor_model: fake_indoor_model)

          controller.with_unlocked(entity) { assert_equal false, entity.locked? }

          assert_equal false, entity.locked?
        end

        def test_apply_unlocks_primal_and_cell_spaces_when_editing
          primal = fake_entity(locked: true)
          cell_group = fake_entity(locked: true)
          indoor_model = fake_indoor_model(primal_group: primal, cell_spaces: [fake_cell_space(cell_group)])
          controller = EditorSession::LockController.new(indoor_model: indoor_model)

          assert_equal true, controller.apply(editing: true)

          assert_equal false, primal.locked?
          assert_equal false, cell_group.locked?
        end

        def test_apply_does_not_change_locks_when_not_editing
          primal = fake_entity(locked: true)
          cell_group = fake_entity(locked: true)
          indoor_model = fake_indoor_model(primal_group: primal, cell_spaces: [fake_cell_space(cell_group)])
          controller = EditorSession::LockController.new(indoor_model: indoor_model)

          assert_equal true, controller.apply(editing: false)

          assert_equal true, primal.locked?
          assert_equal true, cell_group.locked?
        end

        private

        def fake_entity(locked:)
          Class.new do
            def initialize(locked)
              @locked = locked
            end

            def valid?
              true
            end

            def locked?
              @locked == true
            end

            def locked=(value)
              @locked = value == true
            end
          end.new(locked)
        end

        def fake_cell_space(group)
          Struct.new(:sketchup_group).new(group)
        end

        def fake_indoor_model(primal_group: nil, cell_spaces: [])
          Struct.new(:primal_group, :cell_spaces).new(primal_group, cell_spaces)
        end
      end
    end
  end
end
