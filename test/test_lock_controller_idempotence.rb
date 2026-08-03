# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/infrastructure/scene/editor_session/lock_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LockControllerIdempotenceTest < Minitest::Test
        FakeCellSpace = Struct.new(:sketchup_group)

        class FakeIndoorModel
          attr_reader :primal_group, :cell_spaces

          def initialize(primal_group:, cell_spaces:)
            @primal_group = primal_group
            @cell_spaces = cell_spaces
          end
        end

        class FakeEntity
          attr_reader :write_count

          def initialize(locked:)
            @locked = locked
            @write_count = 0
          end

          def valid?
            true
          end

          def locked?
            @locked
          end

          def locked=(value)
            @write_count += 1
            @locked = value
          end
        end

        def test_unlock_does_not_write_when_entity_is_already_unlocked
          entity = FakeEntity.new(locked: false)
          controller = EditorSession::LockController.new(
            indoor_model: FakeIndoorModel.new(primal_group: entity, cell_spaces: [])
          )

          assert controller.unlock_entity(entity)
          assert_equal 0, entity.write_count
        end

        def test_lock_writes_once_and_repeated_lock_is_noop
          entity = FakeEntity.new(locked: false)
          controller = EditorSession::LockController.new(
            indoor_model: FakeIndoorModel.new(primal_group: nil, cell_spaces: [])
          )

          assert controller.lock_entity(entity)
          assert controller.lock_entity(entity)

          assert entity.locked?
          assert_equal 1, entity.write_count
        end

        def test_apply_skips_all_already_unlocked_entities
          primal = FakeEntity.new(locked: false)
          cell_group = FakeEntity.new(locked: false)
          model = FakeIndoorModel.new(
            primal_group: primal,
            cell_spaces: [FakeCellSpace.new(cell_group)]
          )
          controller = EditorSession::LockController.new(indoor_model: model)

          assert controller.apply(editing: true)
          assert_equal 0, primal.write_count
          assert_equal 0, cell_group.write_count
        end
      end
    end
  end
end
