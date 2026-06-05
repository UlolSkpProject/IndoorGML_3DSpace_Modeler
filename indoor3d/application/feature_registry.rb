# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class FeatureRegistry
        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :adjacent_cell_space_pairs
        attr_reader :transitions_by_cell_pair

        def initialize
          reset!
        end

        def reset!
          @cell_spaces = []
          @states = []
          @transitions = []
          @cell_spaces_by_entity_object = {}
          @cell_spaces_by_persistent_id = {}
          @cell_spaces_by_entity_id_for_removed_callback = {}
          @adjacent_cell_space_pairs = {}
          @transitions_by_cell_pair = {}
        end

        def add_cell_space(cell_space)
          @cell_spaces << cell_space unless @cell_spaces.include?(cell_space)
          @cell_spaces_by_entity_object[cell_space.sketchup_group] = cell_space
          @cell_spaces_by_persistent_id[cell_space.sketchup_group.persistent_id] = cell_space
          @cell_spaces_by_entity_id_for_removed_callback[cell_space.sketchup_group.entityID] = cell_space
        end

        def remove_cell_space(cell_space)
          return if cell_space.nil?

          @cell_spaces.delete(cell_space)
          @cell_spaces_by_entity_object.delete(cell_space.sketchup_group)
          @cell_spaces_by_persistent_id.delete(cell_space.sketchup_group_id)
          @cell_spaces_by_entity_id_for_removed_callback.delete_if { |_entity_id, mapped_cell_space| mapped_cell_space == cell_space }
        end

        def find_cell_space_for_entity(entity)
          @cell_spaces_by_entity_object[entity] ||
            find_cell_space_by_persistent_id(entity.persistent_id) ||
            find_cell_space_by_removed_entity_id(entity.entityID)
        rescue StandardError
          @cell_spaces_by_entity_object[entity]
        end

        def find_cell_space_by_persistent_id(persistent_id)
          @cell_spaces_by_persistent_id[persistent_id]
        end

        def find_cell_space_by_removed_entity_id(entity_id)
          @cell_spaces_by_entity_id_for_removed_callback[entity_id]
        end

        def add_state(state)
          @states << state unless @states.include?(state)
        end

        def remove_state(state)
          return if state.nil?

          @states.delete(state)
        end

        def add_transition(transition, pair_key: nil)
          @transitions << transition unless @transitions.include?(transition)
          @transitions_by_cell_pair[pair_key] = transition if pair_key
        end

        def remove_transition(transition)
          return if transition.nil?

          @transitions.delete(transition)
          @transitions_by_cell_pair.delete_if { |_pair_key, mapped_transition| mapped_transition == transition }
        end

        def transition_for_pair(pair_key)
          @transitions_by_cell_pair[pair_key]
        end

        def set_transition_for_pair(pair_key, transition)
          @transitions_by_cell_pair[pair_key] = transition
        end

        def delete_transition_for_pair(pair_key)
          @transitions_by_cell_pair.delete(pair_key)
        end

        def transition_pair_keys
          @transitions_by_cell_pair.keys
        end

        def set_adjacent_pair(pair_key, cell1, cell2)
          @adjacent_cell_space_pairs[pair_key] = [cell1, cell2]
        end

        def delete_adjacent_pair(pair_key)
          @adjacent_cell_space_pairs.delete(pair_key)
        end

        def adjacent_pair_keys
          @adjacent_cell_space_pairs.keys
        end
      end

    end
  end
end
