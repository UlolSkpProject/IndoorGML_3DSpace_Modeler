# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class FeatureRegistry
        attr_reader :cell_spaces
        attr_reader :states
        attr_reader :transitions
        attr_reader :doors
        attr_reader :adjacent_cell_space_pairs
        attr_reader :transitions_by_cell_pair

        def initialize
          reset!
        end

        def reset!
          @cell_spaces = []
          @states = []
          @transitions = []
          @doors = []
          @cell_spaces_by_entity = {}
          @cell_spaces_by_entity_id = {}
          @cell_spaces_by_sketchup_entity_id = {}
          @states_by_entity = {}
          @states_by_entity_id = {}
          @states_by_sketchup_entity_id = {}
          @transitions_by_entity = {}
          @transitions_by_entity_id = {}
          @transitions_by_sketchup_entity_id = {}
          @adjacent_cell_space_pairs = {}
          @transitions_by_cell_pair = {}
        end

        def add_cell_space(cell_space)
          @cell_spaces << cell_space unless @cell_spaces.include?(cell_space)
          add_cell_space_type_reference(cell_space)
          @cell_spaces_by_entity[cell_space.sketchup_group] = cell_space
          @cell_spaces_by_entity_id[cell_space.sketchup_group.persistent_id] = cell_space
          @cell_spaces_by_sketchup_entity_id[cell_space.sketchup_group.entityID] = cell_space
        end

        def remove_cell_space(cell_space)
          return if cell_space.nil?

          @cell_spaces.delete(cell_space)
          remove_cell_space_type_reference(cell_space)
          @cell_spaces_by_entity.delete(cell_space.sketchup_group)
          @cell_spaces_by_entity_id.delete(cell_space.sketchup_group_id)
          @cell_spaces_by_sketchup_entity_id.delete_if { |_entity_id, mapped_cell_space| mapped_cell_space == cell_space }
        end

        def find_cell_space_for_entity(entity)
          @cell_spaces_by_entity[entity] ||
            @cell_spaces_by_entity_id[entity.persistent_id] ||
            @cell_spaces_by_sketchup_entity_id[entity.entityID]
        rescue StandardError
          @cell_spaces_by_entity[entity]
        end

        def cell_space_by_sketchup_entity_id(entity_id)
          @cell_spaces_by_sketchup_entity_id[entity_id]
        end

        def add_state(state)
          @states << state unless @states.include?(state)
        end

        def remove_state(state)
          return if state.nil?

          @states.delete(state)
          @states_by_sketchup_entity_id.delete_if { |_entity_id, mapped_state| mapped_state == state }
        end

        def find_state_for_entity(entity)
          @states_by_entity[entity] ||
            @states_by_entity_id[entity.persistent_id] ||
            @states_by_sketchup_entity_id[entity.entityID]
        rescue StandardError
          @states_by_entity[entity]
        end

        def state_by_sketchup_entity_id(entity_id)
          @states_by_sketchup_entity_id[entity_id]
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

        def transition_by_sketchup_entity_id(entity_id)
          @transitions_by_sketchup_entity_id[entity_id]
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

        def add_cell_space_type_reference(cell_space)
          return if cell_space.nil?

          @doors << cell_space if cell_space.cell_type == CellSpaceType::CONNECTION && !@doors.include?(cell_space)
        end

        def remove_cell_space_type_reference(cell_space)
          return if cell_space.nil?

          @doors.delete(cell_space)
        end

        def register_transition_entity(transition)
          transition
        end

        def unregister_transition_entity(transition)
          return if transition.nil?
          @transitions_by_sketchup_entity_id.delete_if { |_entity_id, mapped_transition| mapped_transition == transition }
        end
      end

    end
  end
end
