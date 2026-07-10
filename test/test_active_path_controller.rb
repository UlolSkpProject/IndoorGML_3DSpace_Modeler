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

        def test_normalize_for_cell_space_creation_closes_to_model_outside_edit_context_and_preserves_selection
          selected = FakeEntity.new
          model = FakeModel.new([FakeEntity.new], selection: FakeSelection.new([selected]))

          assert ActivePathController.new(model).normalize_for_cell_space_creation(
            primal_group: FakeEntity.new,
            edit_context: false
          )

          assert_nil model.active_path
          assert_equal [selected], model.selection.to_a
          assert_equal 1, model.selection.clear_count
          assert_equal [selected], model.selection.added
        end

        def test_normalize_for_cell_space_creation_sets_primal_path_in_edit_context_and_preserves_selection
          selected = FakeEntity.new
          primal = FakeEntity.new
          model = FakeModel.new([FakeEntity.new], selection: FakeSelection.new([selected]))

          assert ActivePathController.new(model).normalize_for_cell_space_creation(
            primal_group: primal,
            edit_context: true
          )

          assert_equal [primal], model.active_path
          assert_equal [selected], model.selection.to_a
        end

        def test_normalize_for_cell_space_creation_fails_in_edit_context_without_valid_primal_group
          model = FakeModel.new([FakeEntity.new])

          refute ActivePathController.new(model).normalize_for_cell_space_creation(
            primal_group: nil,
            edit_context: true
          )
        end

        class FakeEntity
          def valid?
            true
          end
        end

        class FakeSelection
          attr_reader :clear_count, :added

          def initialize(items)
            @items = Array(items)
            @clear_count = 0
            @added = []
          end

          def to_a
            @items.dup
          end

          def clear
            @clear_count += 1
            @items.clear
          end

          def add(entity)
            @added << entity
            @items << entity
          end
        end

        class FakeModel
          attr_reader :close_count

          def initialize(active_path, selection: FakeSelection.new([]))
            @active_path = active_path
            @close_count = 0
            @selection = selection
          end

          attr_accessor :active_path
          attr_reader :selection

          def close_active
            @close_count += 1
            @active_path = nil
          end
        end
      end
    end
  end
end
