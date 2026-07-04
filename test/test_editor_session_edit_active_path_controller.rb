# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/editor_session/edit_active_path_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionEditActivePathControllerTest < Minitest::Test
        def test_tracks_cell_space_geometry_target
          primal = FakeEntity.new
          cell_group = FakeEntity.new
          cell_space = FakeCellSpace.new(cell_group)
          indoor_model = FakeIndoorModel.new(primal, [cell_space])
          controller = build_controller(indoor_model)

          controller.set_target_path([primal, cell_group])

          assert controller.cell_space_geometry_editing?(editing: true)
          assert_equal cell_space, controller.editing_cell_space
        end

        def test_active_path_escape_restores_current_target
          primal = FakeEntity.new
          cell_group = FakeEntity.new
          indoor_model = FakeIndoorModel.new(primal, [FakeCellSpace.new(cell_group)])
          callbacks = CallbackLog.new
          controller = build_controller(indoor_model, callbacks)
          model = FakeModel.new(nil)

          controller.set_target_path([primal, cell_group])
          controller.active_path_changed(model, editing: true, reenter: -> { callbacks.reenter })

          assert_equal [primal, cell_group], model.active_path
          assert_equal 1, callbacks.selection_count
          assert_equal 1, callbacks.invalidate_count
          assert_equal 0, callbacks.lock_count
          assert_equal 0, callbacks.reenter_count
        end

        def test_user_entering_cell_space_path_updates_target
          primal = FakeEntity.new
          old_cell_group = FakeEntity.new
          new_cell_group = FakeEntity.new
          indoor_model = FakeIndoorModel.new(primal, [FakeCellSpace.new(new_cell_group)])
          callbacks = CallbackLog.new
          controller = build_controller(indoor_model, callbacks)
          model = FakeModel.new([primal, new_cell_group])

          controller.set_target_path([primal, old_cell_group])
          controller.active_path_changed(model, editing: true, reenter: -> { callbacks.reenter })

          assert_equal [primal, new_cell_group], controller.target_path
          assert_equal 1, callbacks.lock_count
          assert_equal 1, callbacks.selection_count
          assert_equal 1, callbacks.invalidate_count
        end

        def test_prepare_for_finish_collapses_nested_primal_path
          primal = FakeEntity.new
          cell_group = FakeEntity.new
          indoor_model = FakeIndoorModel.new(primal, [FakeCellSpace.new(cell_group)])
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, cell_group])

          controller.set_target_path([primal, cell_group])
          controller.prepare_for_finish(model)

          assert_equal [primal], model.active_path
        end

        def test_primal_active_path_reenters_when_editing_is_inactive
          primal = FakeEntity.new
          indoor_model = FakeIndoorModel.new(primal, [])
          callbacks = CallbackLog.new
          controller = build_controller(indoor_model, callbacks)
          model = FakeModel.new([primal])

          controller.active_path_changed(model, editing: false, reenter: -> { callbacks.reenter })

          assert_equal 1, callbacks.reenter_count
        end

        def test_reconcile_after_runtime_restore_reconnects_current_cell_space_path
          primal = FakeEntity.new
          stale_cell_group = FakeEntity.new
          current_cell_group = FakeEntity.new
          indoor_model = FakeIndoorModel.new(primal, [FakeCellSpace.new(current_cell_group)])
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, current_cell_group])

          controller.set_target_path([primal, stale_cell_group])
          controller.reconcile_after_runtime_restore(model, editing: true)

          assert_equal [primal, current_cell_group], controller.target_path
          assert_equal indoor_model.cell_spaces.first, controller.editing_cell_space
        end

        def test_reconcile_after_runtime_restore_falls_back_to_primal_when_target_disappears
          primal = FakeEntity.new
          missing_cell_group = FakeEntity.new(valid: false)
          indoor_model = FakeIndoorModel.new(primal, [])
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, missing_cell_group])

          controller.set_target_path([primal, missing_cell_group])
          controller.reconcile_after_runtime_restore(model, editing: true)

          assert_equal [primal], controller.target_path
          assert_nil controller.editing_cell_space
        end

        def test_transaction_replay_reconciles_cell_path_without_active_path_write
          primal = FakeEntity.new
          cell_group = FakeEntity.new
          indoor_model = FakeIndoorModel.new(primal, [FakeCellSpace.new(cell_group)])
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, cell_group])

          controller.set_target_path([primal])
          controller.reconcile_transaction_replay_path(model, editing: true)

          assert_equal [primal, cell_group], controller.target_path
          assert_equal 0, model.active_path_write_count
        end

        def test_transaction_replay_suspends_target_at_root_without_active_path_write
          primal = FakeEntity.new
          cell_group = FakeEntity.new
          indoor_model = FakeIndoorModel.new(primal, [FakeCellSpace.new(cell_group)])
          controller = build_controller(indoor_model)
          model = FakeModel.new(nil)

          controller.set_target_path([primal, cell_group])
          controller.reconcile_transaction_replay_path(model, editing: true)

          assert_empty controller.target_path
          refute controller.cell_space_geometry_editing?(editing: true)
          assert_equal 0, model.active_path_write_count
        end

        def test_transaction_replay_suspends_invalid_path_without_active_path_write
          primal = FakeEntity.new
          invalid_cell_group = FakeEntity.new(valid: false)
          indoor_model = FakeIndoorModel.new(primal, [])
          controller = build_controller(indoor_model)
          model = FakeModel.new([primal, invalid_cell_group])

          controller.set_target_path([primal, invalid_cell_group])
          controller.reconcile_transaction_replay_path(model, editing: true)

          assert_empty controller.target_path
          assert_nil controller.editing_cell_space
          assert_equal 0, model.active_path_write_count
        end

        private

        def build_controller(indoor_model, callbacks = CallbackLog.new)
          EditorSession::EditActivePathController.new(
            indoor_model: indoor_model,
            on_lock: -> { callbacks.lock },
            on_selection: -> { callbacks.selection },
            on_invalidate: ->(_model) { callbacks.invalidate }
          )
        end

        class CallbackLog
          attr_reader :lock_count, :selection_count, :invalidate_count, :reenter_count

          def initialize
            @lock_count = 0
            @selection_count = 0
            @invalidate_count = 0
            @reenter_count = 0
          end

          def lock
            @lock_count += 1
          end

          def selection
            @selection_count += 1
          end

          def invalidate
            @invalidate_count += 1
          end

          def reenter
            @reenter_count += 1
          end
        end

        class FakeEntity
          def initialize(valid: true)
            @valid = valid
          end

          def valid?
            @valid == true
          end
        end

        class FakeCellSpace
          attr_reader :sketchup_group

          def initialize(group)
            @sketchup_group = group
          end

          def valid?
            true
          end
        end

        class FakeIndoorModel
          attr_reader :primal_group, :cell_spaces

          def initialize(primal_group, cell_spaces)
            @primal_group = primal_group
            @cell_spaces = cell_spaces
          end
        end

        class FakeModel
          attr_reader :active_path, :active_path_write_count

          def initialize(active_path)
            @active_path = active_path
            @active_path_write_count = 0
          end

          def active_path=(path)
            @active_path_write_count += 1
            @active_path = path
          end

          def close_active
            @active_path = nil
          end
        end
      end
    end
  end
end
