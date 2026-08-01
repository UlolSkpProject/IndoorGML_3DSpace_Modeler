# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      module UiFeedback
        def self.defer_modal(_message); end
      end

      class IndoorModel; end
    end
  end
end

require_relative '../indoor3d/application/indoor_model/cell_space_demotion_batch'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceDemotionBatchTest < Minitest::Test
        Group = Struct.new(:name) do
          def valid? = true
        end

        class State
          attr_reader :name

          def initialize(name, events)
            @name = name
            @events = events
          end

          def valid? = true

          def erase!
            @events << [:state_erase, name]
          end
        end

        CellSpace = Struct.new(:name, :sketchup_group, :duality_state) do
          def valid? = true
        end

        class Transition
          attr_reader :name, :states

          def initialize(name, states)
            @name = name
            @states = states
          end

          def connected_to?(state)
            states.include?(state)
          end
        end

        class FeatureRegistry
          def initialize(events)
            @events = events
          end

          def delete_transition_for_pair(key)
            @events << [:pair_transition_delete, key]
          end

          def delete_adjacent_pair(key)
            @events << [:pair_adjacency_delete, key]
          end
        end

        class AttributeSerializer
          def initialize(events)
            @events = events
          end

          def clear_indoor_gml_attributes(group)
            @events << [:attributes, group.name]
          end
        end

        class SceneGuard
          def initialize(events)
            @events = events
          end

          def untrack(group)
            @events << [:scene_untrack, group.name]
          end
        end

        class Host
          include IndoorModel::CellSpaceDemotionBatch

          attr_reader :events, :restored_snapshot

          def initialize(cell_spaces, transitions, events = [])
            @cell_spaces = cell_spaces
            @transitions = transitions
            @events = events
            @feature_registry = FeatureRegistry.new(@events)
            @attribute_serializer = AttributeSerializer.new(@events)
            @scene_group_guard = SceneGuard.new(@events)
            @cell_space_change_snapshots = cell_spaces.to_h do |cell_space|
              [cell_space.sketchup_group.name, true]
            end
          end

          def run(cell_spaces)
            send(:perform_selected_cell_space_demotion, cell_spaces)
          end

          private

          def bulk_conversion_runtime_snapshot = :runtime_snapshot

          def restore_bulk_conversion_runtime(snapshot)
            @restored_snapshot = snapshot
          end

          def with_validation_focus_mutation_batch
            @events << [:batch_begin]
            result = yield
            @events << [:batch_end]
            result
          end

          def with_indoor_model_operation(_name)
            @events << [:operation_begin]
            result = yield
            @events << [:operation_end]
            result
          end

          def sync
            @events << [:sync_begin]
            result = yield
            @events << [:sync_end]
            result
          end

          def erase_guard
            @events << [:erase_guard_begin]
            result = yield
            @events << [:erase_guard_end]
            result
          end

          def clear_cell_space_materials(group)
            @events << [:material, group.name]
            true
          end

          def transition_cell_pair_key(transition)
            "pair-#{transition.name}"
          end

          def erase_transition(transition)
            @events << [:transition, transition.name]
          end

          def unregister_state(state)
            @events << [:state_unregister, state.name]
          end

          def unregister_cell_space(cell_space)
            @events << [:cell_unregister, cell_space.name]
          end

          def erase_adjacency_for_cell_space(cell_space)
            @events << [:adjacency_remove, cell_space.name]
          end

          def indoor_gml_attribute_dictionary_empty?(_group) = true

          def entity_observer_key(group) = group.name

          def unlock_indoor_entity(group)
            @events << [:unlock, group.name]
          end

          def untrack_demoted_primal_entities(groups)
            @events << [:primal_untrack, groups.map(&:name)]
          end

          def refresh_after_selected_cell_space_demotion
            @events << [:ui_projection_refresh]
          end
        end

        def build_fixture
          events = []
          group_a = Group.new('group-a')
          group_b = Group.new('group-b')
          state_a = State.new('state-a', events)
          state_b = State.new('state-b', events)
          state_c = State.new('state-c', events)
          cell_a = CellSpace.new('cell-a', group_a, state_a)
          cell_b = CellSpace.new('cell-b', group_b, state_b)
          transition_ab = Transition.new('ab', [state_a, state_b])
          transition_ac = Transition.new('ac', [state_a, state_c])
          [events, [cell_a, cell_b], [transition_ab, transition_ac]]
        end

        def test_multiple_cells_are_processed_by_global_stages
          events, cell_spaces, transitions = build_fixture
          host = Host.new(cell_spaces, transitions, events)

          assert host.run(cell_spaces)
          categories = host.events.map(&:first)

          assert_operator categories.rindex(:material), :<, categories.index(:transition)
          assert_operator categories.rindex(:transition), :<, categories.index(:state_erase)
          assert_operator categories.rindex(:state_unregister), :<, categories.index(:cell_unregister)
          assert_operator categories.rindex(:cell_unregister), :<, categories.index(:adjacency_remove)
          assert_operator categories.rindex(:adjacency_remove), :<, categories.index(:attributes)
          assert_operator categories.rindex(:attributes), :<, categories.index(:scene_untrack)
          assert_equal 2, categories.count(:transition)
          assert_equal 1, categories.count(:ui_projection_refresh)
        end

        def test_single_cell_uses_the_same_batch_path
          events, cell_spaces, transitions = build_fixture
          host = Host.new(cell_spaces, transitions, events)

          assert host.run([cell_spaces.first])
          categories = host.events.map(&:first)

          assert_includes categories, :batch_begin
          assert_includes categories, :material
          assert_includes categories, :transition
          assert_includes categories, :state_erase
          assert_includes categories, :cell_unregister
          assert_includes categories, :adjacency_remove
          assert_includes categories, :attributes
          assert_equal 1, categories.count(:ui_projection_refresh)
        end
      end
    end
  end
end
