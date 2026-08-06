# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      CellSpaceTypeChangeTestCell = Struct.new(:id, :navigable, :duality_state) do
        def valid?
          true
        end

        def navigable?
          navigable
        end
      end

      CellSpaceTypeChangeTestTransition = Struct.new(:state, :pair_key) do
        def connected_to?(candidate)
          state == candidate
        end
      end

      class CellSpaceTypeChangeTestRegistry
        attr_reader :deleted_transitions, :deleted_adjacency

        def initialize
          @deleted_transitions = []
          @deleted_adjacency = []
        end

        def delete_transition_for_pair(key)
          @deleted_transitions << key
        end

        def delete_adjacent_pair(key)
          @deleted_adjacency << key
        end
      end

      class CellSpaceTypeChangeTestLifecycle
        def change_type(cell_space, cell_type:, category_code:)
          cell_space.navigable = cell_type == :navigable
          cell_space
        end
      end

      class IndoorModel
        attr_reader :type_change_test_synchronized,
                    :type_change_test_erased,
                    :type_change_test_materials,
                    :type_change_test_locks,
                    :type_change_test_dirty_clears,
                    :type_change_test_full_syncs,
                    :feature_registry

        def initialize(cell_spaces)
          @type_change_test_cell_spaces = cell_spaces.to_h do |cell_space|
            [cell_space.id, cell_space]
          end
          @type_change_test_synchronized = []
          @type_change_test_erased = []
          @type_change_test_materials = []
          @type_change_test_locks = 0
          @type_change_test_dirty_clears = 0
          @type_change_test_full_syncs = 0
          @transitions = cell_spaces.map do |cell_space|
            CellSpaceTypeChangeTestTransition.new(
              cell_space.duality_state,
              "pair-#{cell_space.id}"
            )
          end
          @feature_registry = CellSpaceTypeChangeTestRegistry.new
        end

        private

        def find_cell_space_for_entity(group)
          @type_change_test_cell_spaces[group]
        end

        def tag_cell_space_type_change_target(_cell_space, cell_type, category_code)
          [cell_type, category_code]
        end

        def with_validation_focus_mutation_batch
          yield
        end

        def with_bulk_cell_space_conversion
          yield
        end

        def with_indoor_model_operation(_name, force:)
          yield
        end

        def sync
          yield
        end

        def cell_space_lifecycle_service
          @type_change_test_lifecycle ||= CellSpaceTypeChangeTestLifecycle.new
        end

        def apply_cell_space_materials_batch(cell_spaces)
          @type_change_test_materials.concat(cell_spaces.map(&:id))
        end

        def apply_indoor_lock_policy
          @type_change_test_locks += 1
        end

        def synchronize_adjacency_and_transitions_for_cell_space(cell_space)
          @type_change_test_synchronized << cell_space.id
        end

        def transition_cell_pair_key(transition)
          transition.pair_key
        end

        def erase_transition(transition)
          @type_change_test_erased << transition.state
          @transitions.delete(transition)
        end

        def clear_bulk_dirty_topology
          @type_change_test_dirty_clears += 1
        end

        def synchronize_topology_after_bulk_conversion
          @type_change_test_full_syncs += 1
        end
      end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_type_change_optimization'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceTypeChangeOptimizationTest < Minitest::Test
        def test_non_navigable_to_navigable_recalculates_only_target
          cell_space = CellSpaceTypeChangeTestCell.new('A', false, :state_a)
          model = IndoorModel.new([cell_space])

          model.change_cell_space_types(['A'], :navigable)

          assert_equal ['A'], model.type_change_test_synchronized
          assert_empty model.type_change_test_erased
          assert_equal ['A'], model.type_change_test_materials
          assert_equal 1, model.type_change_test_locks
          assert_equal 0, model.type_change_test_full_syncs
          assert_equal 0, model.type_change_test_dirty_clears
        end

        def test_navigable_to_navigable_skips_topology
          cell_space = CellSpaceTypeChangeTestCell.new('A', true, :state_a)
          model = IndoorModel.new([cell_space])

          model.change_cell_space_types(['A'], :navigable)

          assert_empty model.type_change_test_synchronized
          assert_empty model.type_change_test_erased
          assert_equal 0, model.type_change_test_full_syncs
        end

        def test_non_navigable_to_non_navigable_skips_topology
          cell_space = CellSpaceTypeChangeTestCell.new('A', false, :state_a)
          model = IndoorModel.new([cell_space])

          model.change_cell_space_types(['A'], :window)

          assert_empty model.type_change_test_synchronized
          assert_empty model.type_change_test_erased
          assert_equal 0, model.type_change_test_full_syncs
        end

        def test_navigable_to_non_navigable_removes_transition_only
          cell_space = CellSpaceTypeChangeTestCell.new('A', true, :state_a)
          model = IndoorModel.new([cell_space])

          model.change_cell_space_types(['A'], :window)

          assert_empty model.type_change_test_synchronized
          assert_equal [:state_a], model.type_change_test_erased
          assert_equal ['pair-A'], model.feature_registry.deleted_transitions
          assert_empty model.feature_registry.deleted_adjacency
          assert_equal 0, model.type_change_test_full_syncs
          assert_equal 0, model.type_change_test_dirty_clears
        end

        def test_mixed_batch_applies_only_required_topology_actions
          cell_spaces = [
            CellSpaceTypeChangeTestCell.new('A', false, :state_a),
            CellSpaceTypeChangeTestCell.new('B', true, :state_b),
            CellSpaceTypeChangeTestCell.new('C', true, :state_c)
          ]
          model = IndoorModel.new(cell_spaces)

          model.change_cell_space_types(%w[A B], :navigable)
          model.change_cell_space_types(['C'], :window)

          assert_equal ['A'], model.type_change_test_synchronized
          assert_equal [:state_c], model.type_change_test_erased
          assert_equal 0, model.type_change_test_full_syncs
          assert_equal 0, model.type_change_test_dirty_clears
        end
      end
    end
  end
end
