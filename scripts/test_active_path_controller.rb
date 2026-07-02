# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/infrastructure/scene/active_path_controller'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ActivePathControllerTest < Minitest::Test
        def test_snapshot_duplicates_active_path
          entity = FakeEntity.new
          model = FakeModel.new([entity])

          snapshot = ActivePathController.new(model).snapshot

          assert_equal [entity], snapshot
          refute_same model.active_path, snapshot
        end

        def test_close_to_root_closes_until_path_is_nil
          model = FakeModel.new([FakeEntity.new, FakeEntity.new])

          assert ActivePathController.new(model).close_to_root

          assert_nil model.active_path
          assert_equal 1, model.close_count
        end

        def test_restore_sets_valid_path
          entity = FakeEntity.new
          model = FakeModel.new(nil)

          assert ActivePathController.new(model).restore([entity])

          assert_equal [entity], model.active_path
        end

        def test_restore_nil_closes_when_requested
          model = FakeModel.new([FakeEntity.new])

          assert ActivePathController.new(model).restore(nil, close_when_nil: true)

          assert_nil model.active_path
        end

        def test_restore_nil_can_noop
          original = [FakeEntity.new]
          model = FakeModel.new(original.dup)

          refute ActivePathController.new(model).restore(nil, close_when_nil: false)

          assert_equal original, model.active_path
        end

        def test_matches_compares_path_members
          entity = FakeEntity.new
          model = FakeModel.new([entity])

          controller = ActivePathController.new(model)

          assert controller.matches?([entity])
          refute controller.matches?([FakeEntity.new])
        end

        class FakeEntity
          def valid?
            true
          end
        end

        class FakeModel
          attr_reader :close_count

          def initialize(active_path)
            @active_path = active_path
            @close_count = 0
          end

          attr_accessor :active_path

          def close_active
            @close_count += 1
            @active_path = nil
          end
        end
      end
    end
  end
end
